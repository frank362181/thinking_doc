上一章分析了openclaw agent --message "..."的执行路径。表面上看，这条命令只是发送一条消息，但源码中实际经历了参数校验、Agent选择、session选择、模型覆盖、Gateway调用、本地fallback等多个环节。

这一期要解决以下几个问题：
-   为何OpenClaw要将Agent请求交给Gateway
-   Gateway在系统里扮演什么角色？
-   CLI、webUI、移动端节点、channel为何都要链接Gateway
-   Gateway的websocket RPC请求是如何组织的？
-   Gateway是如何根据method找到对应的函数的？

OpenClaw官方架构文档说明：Gateway是一个长期运行的进程，负责维护消息渠道链接，并通过WebSocket API暴露请求、响应和服务端推送事件；CLI、webUI、macOS APP、自动化恩物等控制平面客户端都通过WebSocket链接到Gateway，默认地址是 127：0.0.1：18789.

### 为何要单独讲Gateway
前面几章都提到了Gateway，但是没有真正拆解开来过。在OpenClaw中，Gateway不是一个普通的HTTP后端，也不是单纯的模型转发服务。更像是一个个人AI助手系统的“中枢”。在官方文档中写到：OpenClaw是一个单一、长期运行的进程，负责所有消息入口，例如像WhatsApp、Telegram、Slack、Discord、Signal、Wechat等；同时，控制面板客户端通过WebSocket接入Gateway，节点设备也通过同一个WebSocket接入，只是会申明role:node并携带自己的能力和命令。也就是说Gateway不是替模型回答问题，而是：
-   统一接收请求
-   统一验证身份和权限
-   统一管理会话和状态
-   统一调度Agent运行
-   统一处理channel链接
-   统一推送事件给客户端

### Gateway的运行模型
OpenClaw官方中说明，Gateway是一个长期运行的进程，承担路由、控制面板、和Channel链接；同一个端口同时承载WebSocket控制/RPC、OpenAI-compatible HTTP API、插件HTTP路由、Control UI和hooks等，默认绑定模式是loopback，并且默认需要认证。
这说明OpenClaw至少承担了四类能力：
-   第一类：控制面板 PRC：如health、status、agent、send、config、sessions、tools等管理
-   第二类：消息渠道链接：如telegram、slack、discord、wechat等
-   第三类：前端和可视化：如control UI、canvas、A2UI等
-   第四类：兼容接口和插件接口：如/v1/models、/v1/chat/completions、/tools/invokes、插件http路由等

总之，可以理解成：OpenClaw负责发起操作，负责维护长期状态、链接和运行环境，以及负责具体理解和执行任务。

### WebSocket协议的基本格式
OpenClaw Gateway协议使用WebSocket文本帧，内容是JSON payload。协议文档中明确说明：第一个frame必须是connect请求；握手成功后，请求、响应和时间分别使用固定结构。
基本结构可以简化为：
{
    "type":"req",
    "id":"...",
    "method":"agent",
    "params":{}
}
响应结构：
{
    "type":"res",
    "id":"...",
    "ok":true,
    "payload":{}
}
事件结构：
{
    "type":"event",
    "event":"agent",
    "payload":{}
}
官方文档中说明把write protocol总结为：请求是{"type":"req",id,method,params}，响应是{"type":"res",id,ok,payload|error}，事件是{"type":"event",event,payload,seq?,stateVsersion?}。
在解读源码时，只要看到某个方法名，比如：
agent、chat.send、sessions.list、config.get、tools.invoke、channels.status等
就可以理解成客户端发送一个method，Gateway根据method找到对应的handler；handler执行后通过res或event返回结果。

### Gateway握手：为什么第一个请求必须是connect
Gateway协议规定，第一个frame必须时connect请求。握手时，客户端会申明协议版本、客户端信息、role、scopes、caps、commands、auth、device等信息；Gateway返回hello-ok，其中包含协议版本、server信息、features、snapshot、auth和policy等。可以理解成：
普通请求：我想调用某个功能
----------
请求发起的请求包含：
connect请求：
我是谁？
我是什么角色?
我有哪些权限？
我支持哪些能力？
我如何认证？
Gateway当前支持哪些方法和事件？
---------------
握手成功后，Gateway才能知道：
这是CLI还是节点？
这是operator还是node?
它有没有operator.read / operator.write权限？
能不能调用agent？
能不能调用config.set?
能不能为node暴露camera、canvas、screen等命令？

所以，Gateway的第一步请求不是执行请求，而是建立可信链接上下文。

### role、scope和device paring
OpenClaw Gateway不是所有的链接都是一视同仁的。官方架构文档说明，所有的WebSocket客户端都需要携带device identity；新device id需要paring approval，直接本地loopback链接可以自动批准，以保证同主机体验流畅；非本地链接仍然需要显式批准；Gateway auth对本地和远程链接都适用。
这里可以分为三层：
role：链接是什么角色，如operator或node
scope：这个角色有哪些权限，如operator.read，operator.write或operator.admin
device identity/paring：这个链接来自哪里，这个设备是否被信任。
对于CLI来讲，通常是控制面板客户端；对于移动端节点来讲，会声明：role:node，并声明自己具备哪些caps和commnds，例如camera、canvas、screen、location、voice等。协议文档给出的node示例中，node会在connect参数中声明caps和commands。这说明Gateway的设计不只是靠一个token，而是结合了：
-   链接认证；
-   角色识别；
-   权限范围；
-   设备身份；
-   设备配对；
-   本地/远程链接策略。
这对于一个可以控制本地工具、消息渠道和设备节点的个人AI助手系统非常重要。

### Gateway方法：method是如何被分发的？
理解Gateway的关键是理解method到handler的映射。
在src/gateway/server-methods.ts中,Openclaw定义了大量的Gateway RPC方法，并通过createLazyCoreHandler进行懒加载注册。例如源码中可以看到health、status、channels.status、chat.history、chat.send、config.get、config.set、tools.invoke、sessions.list、sessions.send、agent、agent.list等方法都会被注册到coreGatewayHandlers中。
这说明，Gateway的方法体系大致是这样的：
health、status:健康检查
channels相关：渠道状态、启动、停止、登出
chat相关：聊天历史、发送、注入、终止
config相关：读取、修改、schema查询
sessions相关：会话列表、会话创建、会话发送、会话重置、会话压缩等
tools相关：工具目录、有效工具、工具调用；
agent相关：触发agent.run或等待agent结果、agent列表、创建、更新、删除、文件读写等。

OpenClaw并没有将method和handler的映射关系写入到一个巨大的switch或if语句中，而是通过method和handler的模块结合起来，建立映射的map关系实现构建。

### lazy handler的意义
源码中server-methods.ts使用了lazyHandlerModule和createLazyCoreHandlers。从代码结构看，每一类handler都通过动态import加载，例如agent相关方法加载./server-methos/agent.js；sessions相关方法加载./server-methods/session.js；config相关方法加载./server-methods/configs.js。

这是一种非常常见的大型系统设计策略：
Gateway启动时，建立方法注册表，真正请求到来时，再加载对应的handler模块。
这样做的好处是：
-   降低启动时加载的压力
-   让不同方法模块保持独立；
-   避免所有gateway功能挤在一个文件里面；
-   插件或扩展方法更容易接入；
-   后续调试可以按method找到对应的源码文件

比如，当gateway接收到命令是：agent时，就可以沿着源代码找到 :src/gateway/server-methods.ts -> loadAgentHandlers -> src/gateway/server-methods/agent.ts
当命令时method:sessions.send时，沿着元代码找到：src/gateway/server-methods.ts -> loadSessiosHandlers -> src/gateway/server-methods/sessions.ts

### handleGatewayRequest的处理流程
Gateway收到一个请求后，并不是直接开始执行handler。sever-methods.ts中的handleGatewayRequest会先构建或获取method registry，然后做权限校验、启动期不可判断、控制平面写操作限流、handler查找，最后才是调用具体的handler；handler调用会抱在plugin runtime gateway request scope里，以便插件运行时和子Agent等场景可以在正确的Gateway上下文中执行。执行的路径如下描述：
收到req -> 读取method -> 构建method registry -> authorizeGatewayMethod 权限检查 -> 判断gateway startup 阶段该method是否可用 -> 如果是控制平面写操作，检查rate limit -> 根据method 找到handler -> 找不到则执行unknown method -> 执行handler -> 返回res或推送event。
这至少说明gateway请求处理至少 有 4层保护：
-   第一层：链接握手和认证；
-   第二层：role/scope 方法权限检查
-   第三层：启动状态和方法可用性检查
-   第四层：控制平面写操作限流
所以gateway不是简单的method反射调用，而是带有控制面板安全边界的RPC分发系统。
