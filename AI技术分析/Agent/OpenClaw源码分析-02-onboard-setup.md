### 本章摘要
-   setup和onboard的区别？
-   setu命令在源码中做了哪些事情？
-   openclaw.json是如何被创建和更新的？
-   workspace是什么，里面会生成那些文件？
-   sessions目录为什么会在setup阶段创建
-   onboard为什么比setup更加完整?
-   后续源码阅读该如何从配置初始化继续深入？

### 区分setup和onboard
从使用者的角度可以这样理解：
-   openclaw setup 创建了最基础的本地配置和agent workspace
-   openclaw onboard 完整引导用户完成Gateway、模型认证、workspace、channels、skills和健康检查配置
-   openclaw configure: 在已有的配置基础上做局部修改
官方文档写到, openclaw setup初始化baseline config和agent workspace;如果带上onboard相关完整参数，它会触发某些wizard。
而Openclaw onboard则是完整的guide onboarding，适合用户希望OpenClaw一步一步引导完成模型认证、gateway、channel、skills和健康检查等配置。所以，这三个命令的关系可以画成： 
-   第一次最小初始化 -> OpenClaw setup
-   第一次完整引导配置 -> OpenClaw onboard
-   已有配置上的局部修改 -> OpenClaw Configure

### setup命令在CLI体系中的位置
上一篇文章讲到，OpenClaw的CLI命令是通过command descriptor注册进来的，在core-command-descriptors.t中，
-   setup被描述为：initialize local config and an agent workspace.
-   onboard被描述为：Interactive onboarding for gateway,workspace,and skills.
-   configure被描述为：interactive configuration for credentials,channels,gateway,and agent defaults.
虽然这三个命令放在同一组“初始化/配置”命令体系中，但它们解决的问题层次不同：
-   setup:偏底层，负责把本地运行需要的基础目录和基础配置建起来；
-   onboard：偏用户体验，负责把第一次使用OpenClaw的完整流程串起来；
-   configure：偏维护，负责后续配置调整

### setup源码入口
OpenClaw setup对应的核心实现逻辑位于：src/commands/setup.rs，从源码上主要函数是setupCommand，其核心逻辑是：
-   解析用户传入的workspace参数；
-   创建或读取配置IO
-   读取已有openclaw.json
-   计算最终workspace路径
-   构造next config
-   必要时写回配置
-   创建/检查 agent workspace
-   创建/检查 sessions目录
#### setup第一步：确定workspace路径
workspace是OpenClaw中非常重要的概念，简单来讲，源码仓库是程序代码所在的位置，而workspace是用户自己的agent工作区，从工程角度来讲，个人配置和工作区应该放在~/.openclaw下面，而不是写进源码仓库中。
setupCommand会优先读取命令行传入的--workspace参数，如果用户没有传入，就查看已有配置中的agent.defaults.workspace。如果配置里面有，就使用默认的workspace目录，源码中的逻辑可以抽象为：
-   命令行 --workspace 
                |（如果没有）
    已有配置agents.defaults.workspace
                | （如果没有）
        默认workspace目录
官方文档也说明，--workspace <dir> 用于设置agent workspace目录，默认是~/openclaw/workspace，并且会存储到agents.defaults.workspace。所以setup的第一件关键事情，就是把OpenClaw的工作区在哪里确定下来。

#### setup第二步：创建或更新openclaw.json
OpenClaw的主要配置文件是~./openclaw/openclaw.json
官方文档说明，OpenClaw会从~./openclaw/openclas.json读取可选的JSON5配置；如果文件存在，就使用安全默认值。
setupCommand会读取这个配置文件，然后构建一个新的next配置对象，它至少会关注两个地方：
-   agents.defaults.workspace
-   gateway.mode
源码逻辑可以理解成：
nextConfig = {
    ... exisingConfig,
    agents: {
        ...existingConfig.agents,
        defaults: {
            ...existingCOnfig.agents.defaults,
            workspace:最终确定的workspace路劲
        }
    }，
    gateway:{
        ...existingConfig.gateway,
        mode:existingConfig.gateway.mode ?? "local"
    }
}
也就是说，setup并不是粗暴覆盖整个配置文件，而是在已有配置文件的基础上补齐必要字段，源码中也能看得出来，它只有在配置不存在、workspace变化或gateway.mode需要补齐时，才会写回配置。
这体现一个工程习惯：<B>初始化命令应该尽量补齐确实配置，而不是随意覆盖用户已有的配置</B>
                      
##### 为什么要配置gateway.mode
在setupCommand中，除了workspace，另一个关键字是: <B> gateway.mode</B>,源码中默认设置为local,这和openclaw的local-first定位有关，第一次本地初始化时，系统默认把Gateway视为本地模式，而不是远程gateway。onboard文档中也提到，本地onboarding会把gateway.mode="local"写入配置；远程onboarding则只写入远程的gateway配置信息。

#### setup第三步：确保workspace存在
配置写好之后，setupCommand会调用 ensureAgentWorkspace(...)，该函数位于src/agents/workspace.ts，从源码来看，workspace定义了一组默认文件名，包括：
-   AGENTS.md：描述agent的整体行为或多agent的相关规则
-   SOUL.md：偏agent的长期身份、风格或核心行为倾向
-   TOOLS.md：描述工具使用相关约束或说明
-   IDENTITY.md：描述agent的身份信息
-   USER.md：描述用户星官信息或偏好
-   HEARTBEAT.md：描述周期性状态、心跳或维护类行为
-   BOOSTRAP.md：首次启动或首次配置时的引导文件

这些文件是OpenClaw workspace初始化时的重要模板文件，ensureAgentWorkspace会创建workspace目录，并在需要的时候写入缺失的bootstrap文件。OpenClaw的workspace不是一个空目录，而是一组会被Agent读取和使用的行为文件、身份文件和引导文件。

#### setup第四步：创建sessions目录
setupCommand除了配置文件和workspace，还会处理sessions目录，源码中可以看到，在workspace初始化后，会调用resolveSessionTranscriptsDir获取sessions相关目录，然后通过发fs.mkdir(...,{recursive:true})确保目录存在。
这充分说明OpenClaw在初始化时考虑到了"会话记录"这个问题。
因为OpenClaw不是一次性回答程序，他是一个长期运行的个人助手，用户和Agent的对话会被组成不同的session，后续可能会用于上下文恢复、历史查询、调试或多渠道会话隔离。
所以，setup最后创建sessions目录，其实时在为后续Agent运行做准备。
-   配置文件：告诉系统如何运行
-   workspace：告诉agent如何表现
-   sessions：保存Agent与用户之间的交互历史
以上三者共同构建了OpenClaw本地运行的基础状态。

### onboard为何比setup更完整
setup只是解决“基础文件和目录存在”的问题；而onboard解决的是“用户第一次使用OpenClaw时如何完整配hi系统”的问题。官方onboard文档说明，openclaw onboard时完整引导式onboarding，用于配置local或remote Gateway，并覆盖模型认证、workspace、Gateway、channels、skills和health等流程。也就是说：
-   setup只是负责地基；
-   onboard负责从地基到可用系统的一整套装修流程。

Onboard支持不同的flow，如：
-   quickstart：最少提示，快速完成
-   manual：完整提示，适合手动配置端口、绑定地址和认证。
-   import：从已有agent系统迁移
官方文档也列出了这些flow类型：quickstart式Minimal prompts，manual是完整提示，Import会迁移Provider并在确认后应用计划。

#### onboard的交互式和非交互式模式
onboard支持交互式，也支持非交互式；例如官方文档中给出了类似的用法：
<I
openclaw onboard --non-interactive \
    --auth-choice ollama \
    --custom-base-url "http://ollamap-host:11434" \
    --custom-mode-id "qwen3.5:27b" \
    --accept-risk
    
还支持远程Gateway、secreref、gateway token、跳过health、跳过boostrap等配置。
这说明，OpenClaw的初始化既面向普通用户，页面先自动化部署场景：
-   普通用户：openclaw onboard，一步步选择和确认
-   自动化脚本：openclaw onboard --non-interactive ...，直接写入配置并完成初始化
从源码角度来看，onboard比setup更复杂，因为它要处理用户输入、认证方式、模型provider、gateway模式、channel、skills、healthe check甚至迁移逻辑。

#### setup和onboard的调用关系
官方setup文档提到，openclaw setup在带有onboarding相关flag时，也会运行wizard，例如--wizard、--non-interactive、--mode、--import-from、--remote-url、--remote-token等参数都会触发wizard。
所以，可以理解，普通setup只是做基础初始化；setup+onboarding参数，进入更完整的onboarding流程；onboard则将直接进入完整的onboarding流程。

### 配置文件的严格校验
openclaw的配置系统不是随便写JSON就行。官方配置文档明确说明，openclaw只接受<B完全匹配schema的配置，未知字段、类型错误或非法值都会导致Gateway拒绝启动；配置失败时，通常只有doctor、logs、health、status等诊断命令可用。

### 从setup看openclaw的本地状态模型
通过setup命令，可以初步看到openclaw的本地状态模型：
~/.openclaw/openclaw.json
    |
系统配置
    |
~/.openclaw/workspace
    |
agent工作区和行为文件
    |
~/.openclaw/agents/<agentId>/sessions
    |
会话历史与trnnscript

~/.openclaw/credentials
    |
渠道、模型和认证状态

/tmp/openclaw
    |
运行日志