### 命令入口：agent是核心CLI命令之一
在CLI命令描述文件中，agent被注册为一个核心命令，其说明是“run one agent turn via the Gateway”，即通过Gateway运行一次agent回合。这个定义说明，默认情况下OpenClaw倾向于让Agent经过Gateway，而不是直接在当前CLI进程里裸跑模型调用。可以理解为：
用户输入命令
    |
openclaw agent
    |
构造一次agent请求
    |
优先交给gateway执行
    |
得到恢复后输出到终端，或投递到指定的聊天渠道

这种设计的好处是：CLI不需要自己承担全部运行状态。Gateway可以统一管理会话、通道、插件、模型、工具、消息投递和长期运行状态。

### 第一层校验：消息和目标会话必须存在
agent-via-gateway.ts中的agentViaGatewayCommand首先取出用户传入的message，并进行空置校验。如果用户没有传入消息，源码会直接抛出错误，提示使用openclaw agent --message "..." --agent <id>或者使用已有会话参数。

紧接着，还会检查目标会话是否明确，至少用户提供--to、--session-id、--agent或--session-key中的一种，否则系统不知道这次消息该发给哪个agent或哪个会话。这一步可以概括为：
message 为空？ 报错
没有任何会话选择器？ 报错
agent id不存在？报错

这个设计很关键，因为openclaw支持多个agent，也支持把不同聊天渠道映射到不同会话。如果没有明确的目标选择，系统就无法判断这次agent turn应该继承哪段上下文，也无法判断后续恢复应该投递到哪里。

### 第二层校验：解析session key、timeout、model override
通过基础校验之后，源码会继续解析运行参数，它会根据配置和用户传入的agentId、to、sessionId、sessionKey等信息解析出最终使用的sessionKey。同时，它还会解析超时时间、消息渠道、幂等key，以及可选的模型覆盖参数--model。
这一段代码的核心不是“调用模型”，而是把用户输入的CLI参数转换为一次标准化的Agent运行请求。可以理解为：
用户参数
    |
规范化agentId
    |
检查agentId是否存在
    |
解析sessionKey
    |
解析timeout
    |
解析model override
    |
生成idempotentcyKey
其中idempotentcyKey很值得注意，它标识一次请求，避免同一个请求在gateway中被重复执行。源码中还专门处理了in_flight状态；如果相同run已经在执行中，CLI会提示当前Agent run已经在进行，而不是重启一个重复任务。

### Gateway路径：真正向Gateway发起agent调用
参数准备完后，OpenClaw会通过callGateway向Gateway发起请求，这里的请求方法是"agent"，请求参数包括message、agentId、model、to、sessionId、sessionKey、thinking、deliver、channel、replyChannel、timeout、lane和idempotencyKey等。
从这一点可以看出，openclaw agent命令发出的不是一个简单文本请求，而是一个完整的Agent执行请求包，这个请求包同时携带了：
-   要说什么：message
-   由谁执行：agentId
-   使用哪个上下文：sessionKey/sessionId
-   是否覆盖模型：model
-   是否投递回复：deliver
-   投递到哪里：channel/replyChannel/replyTo
-   如何控制运行：timeout/thinking/lane
-   如何避免重复：idempotencyKey
因此，Gateway不是被动转发文本，而是承担了Agent运行控制中心的角色。

### 输出处理：JSON输出与普通文本输出分开
Gateway返回结果后，CLI会根据用户是否传入--json选择不同的输出方式，如果是JSON模式，源码会把Gateway响应写成结构化JSON；如果不是JSON，则会提取payloads，逐个格式化后输出到终端。
这说明openclaw同时面向两类使用方式：
-   直接在终端使用：输出可读文本
-   脚本或自动化系统调用：输出可解析的JSON
这一点对CLI来说很重要，人类用户需要清晰的终端反馈，而自动化脚本需要稳定的结构化返回值。

### 本地路径与回退路径：为什么有local？
官方文档中说明，Gateway模式失败时会回退到embedded agent，而--local可以直接强制使用嵌入式执行；同时，--local仍会预加载插件注册表，以便插件提供的provider、tool和channel在本地运行中仍然可用。

源码中的agentCliCommand也体现了这个分支逻辑：如果用户设置了--local，系统会直接调用agentCommand；如果没有设置--local,则优先尝试agentViaGatewayCommandWithTransientRetries，也就是Gateway路径。可以理解成：
openclaw agent
    |
是否--local
    是：直接agentCommand本地执行
    否：优先Gateway执行
        |
        Gateway失败或超时
            是：embedded fallback
            否：返回Gateway结果
着这种设计增强了可用性，Gateway正常时，系统走统一服务路径；gateway不可用或超时时，CLI仍然有机会在当前进程中完成一次嵌入式Agent执行。

### 嵌入式执行内部：agentCommand做了什么？
当系统进入本地执行或embedded fallback时，会调用agentCommand相关逻辑。agent-command.ts中的prepareAgentCommandExecution会再次检查消息体和会话选择器，并解析配置、Agent、会话、工作区、模型上下文等运行信息。

随后，系统会解析session，得到sessionId、sessionKey、会话存储、是否新会话、持久化thinking/verbose设置等信息；还会解析Agent所属工作目录、Agent目录以及模型manifest上下文。

进入真正执行阶段后，源码会调用acpManager.runTurn，并监听运行过程中的事件。对于text_delta事件，系统会把模型输出的增量文本积累起来，再通过运行时事件发送出去。
执行结束后，源码会整理最终文本，持久化transcript，并调用投递逻辑deliverAgentCommandResult处理最终输出或消息发送。因此嵌入执行链路可以写成：
agentCommand
    |
prepareAgentCommandExecution
    |
解析会话、Agent、工作区、模型上下文
    |
准备skills snapshot
    |
acpManager.runTurn
    |
接收text_delta/done等事件
    |
累积最终回复
    |
保存transcript
    |
输出或投递结果

### 整体执行流程
用户执行：openclaw agent --agent ops --message "Summarize logs"
 
        ↓
 
agentCliCommand
        ↓
规范化参数、校验 sessionKey、生成 runId
        ↓
判断是否 --local
        ↓
┌─────────────────────────────┐
│ Gateway 优先路径             │
│ agentViaGatewayCommand       │
└─────────────────────────────┘
        ↓
校验 message / session selector / agentId
        ↓
解析 sessionKey / timeout / model override
        ↓
callGateway({ method: "agent", params: ... })
        ↓
Gateway 执行 Agent turn
        ↓
返回 response
        ↓
JSON 输出或 payload 文本输出
 
        ↓ 如果 Gateway 失败或超时
┌─────────────────────────────┐
│ embedded fallback            │
│ agentCommand                 │
└─────────────────────────────┘
        ↓
解析配置、会话、Agent、工作区、模型、技能
        ↓
acpManager.runTurn
        ↓
保存 transcript
        ↓
返回或投递结果

### 1. CLI 命令：
openclaw agent --agent <my-assistant> --message "Hello"

### 2. 定位智能体与加载配置
这是初始化的关键一步，系统会根据 --agent <id>去openclaw.json中找到对应的智能体配置：
-   配置文件结构：openclaw.json是核心配置文件，通常位于~/.openclaw/目录下，它采用“分层配置+模块化定义”原则，包含全局默认配置（defaults）和具体的智能体列表（list）
-   智能体定义：每个在agent.lists中定义的智能体都有一个唯一的id，当你在命令中指定--agent my-assistant时，系统就会去list中查找id为my-assistant的配置项，并将其与 defaults中的全局配置合并，形成该智能体的最终配置。一个简化的openclaw.json配置如下：
{
    "agents":{
        "defaults":{
            "model":{"primary":"anthropic/claude-sonnet-4-5"},
            "workspace":"~/.openclaw/workspace"
        }
        "lists":[
            {
                "id":"my-assistant",
                "workspace":"~/my-agent-workspace" //覆盖默认值
                ... //其他配置
            },
        ]
    }
}

### 3.执行智能体 agentCommand
参数和配置就绪后，执行流程进入到agentCommand函数，它的主要职责时准备运行环境，并启动核心的runEmbeddedAgent过程。

### 4.核心执行 runEmbeddedAgent的详细步骤
runEmbeddedAgent函数是智能体运行的发动机，它串联起了整个生命周期，以下是其内部的关键步骤：
#### 1. 会话与工作区准备
-   会话解析：系统会解析sessionKey或sessionId，用于维护对话历史，如果没有指定，通常会基于智能体ID创建一个；
-   工作区加载：系统会解析并创建一个工作区目录，工作区是智能体的“私人文件夹”，它包含它的记忆和各种配置文件，若为全新工作区才会创建，若是初始化过的，则直接使用
-   加载引导文件，这是构建智能体人格的关键，系统会从工作区加载一系列markdown文件,这些文件包含：
    -   AGENTS.md/SOUL.md/IDENTITY.md：定义智能体的身份、性格、基本指令；
    -   USER.m：描述用户信息
    -   TOOLS.md：定义可用的工具
    -   MEMORY.md和memory/目录：存储的长期记忆
    这些文件的内容会被注入到系统提示词中，让模型知道自己是谁，该怎么做：
    export const DEFAULT_AGENTS_FILENAME = "AGENTS.md"
    export const DEFAULT_SOUL_FILENAME = "SOUL.md"
    ....

    以上这些硬编码指定的文件的内容在函 loadWorkspaceBootstrapFiles()函数中按照顺序读读取这些文件的内容

-   加载技能SKILLS，系统会加载智能体配置中定义的skills快照，并将其注入到提示词中，skills是智能体可以执行的具体功能模块

#### 2. 队列与并发控制
为了防止同一个会话的多个请求发生冲突，并保持对胡历史的一致性，runEmbeddedAgent会将运行请求放入队列中按会话串行化执行；同时，对会话文件的写入操作也会受到文件锁的保护；

#### 3. 提示词组装
系统提示词（system prompt）由多个部分动态组装而成：
-   1. OpenClaw的基础提示词
-   2. 从工作区加载的bootstrap上下文（各种.md文件）
-   3. 注入的skills提示词
-   4. 本次运行的特殊覆盖项（如 --mode 指定的模型）

#### 4.模型推理与工具执行
这是智能体“思考”和“行动”的核心环节
-   组装好的提示词和对话历史会被发送给配置好的LLM
-   模型坑你会决定调用工具（Tools），OpenClaw会执行这些工具，并将结果返回给模型，如此循环，知道模型给出最终回复。

#### 5. 事件流式传输与生命周期管理
整个运行过程会通过事件流（event stream）向外广播：
-   生命周期事件：如start、end、error等
-   数据流事件：如assistant、tool
CLI会订阅这些事件，并将模型的回复实时打印到终端

#### 6. 超时控制和结束
整个运行过程受 --timeout参数或配置中的超时时间限制，一旦超时，运行被强制中止。运行结束后，最终的对话记录会被持久化。
