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

## 1. CLI 命令：
openclaw agent --agent <my-assistant> --message "Hello"

## 2. 定位智能体与加载配置
这是初始化的关键一步，系统会根据 --agent <id>去openclaw.json中找到对应的智能体配置：
-   配置文件结构：openclaw.json是核心配置文件，通常位于~/.openclaw/目录下，它采用“分层配置+模块化定义”原则，包含全局默认配置（defaults）和具体的智能体列表（list）
-   智能体定义：每个在agent.lists中定义的智能体都有一个唯一的id，当你在命令中指定--agent my-assistant时，系统就会去list中查找id为my-assistant的配置项，并将其与 defaults中的全局配置合并，形成该智能体的最终配置。一个简化的openclaw.json配置如下：
{
    "agents":{
        "defaults":{
            "model":{"primary":"anthropic/claude-sonnet-4-5"},
            "workspace":"~/.openclaw/workspace"
        }
        "list":[
            {
                "id":"my-assistant",
                "workspace":"~/my-agent-workspace" //覆盖默认值
                ... //其他配置
            },
        ]
    }
}

## 3.执行智能体 agentCommand
参数和配置就绪后，执行流程进入到agentCommand函数，agentCommand函数的调用流程如下图描述所示：
用户执行命令 openclaw agent --agent-id -> CLI 解析命令 -> 调用agentCommand函数 -> agentCommand准备参数 -> 调用loadSkillEntries扫描并加载技能元数据 -> 构建技能快照 Skills Snapshot -> 调用runEmbeddedAgent执行核心Agent循环 -> 组装system prompt注入技能snapshot -> 开始与模型交互

### 1 读取SKILLS
#### 1 准备阶段：扫描、过滤与元数据收集
Skills的读取发生在会话（session）启动或重建时，而不是在每轮对话中都重新读取。
-   核心触发点：当一个会话（由sessionKey标识）被创建或需要重建其上下文时，OpenClaw会执行加载skills的操作
-   配置变更时：当修改了openclaw.json中与skills相关的配置时（例如，在skills.load.extraDirs中添加了新的技能目录），并且该会话的缓存被刷新后，会触发重新加载；
-   文件变更时：如果启用了文件监控（skills.load.watch默认为true），当SKILL.md文件发生变更时，监控器会捕获到事件。但为了防止频繁变更导致性能问题，会有一个默认的250ms的防抖时间。

读取过程遵循一套明确的优先级和过滤规则。
-   发现技能源（Discovery）：OpenClaw会从多个预定义的根目录加载skills，并遵循高优先级覆盖低优先级的规则。优先级从高到低如下：
    优先级	    来源	            路径 (示例)
    1 (最高)	工作区技能	        <workspace>/skills
    2	        项目智能体技能	    <workspace>/.agents/skills
    3	        个人智能体技能	    ~/.agents/skills
    4	        托管/本地技能	    ~/.openclaw/skills
    5	        内置技能	        随 OpenClaw 安装包提供
    6 (最低)	额外目录	        skills.load.extraDirs 配置的路径 + 插件技能

当一个技能名在多个位置出现时，优先级高的路径生效。OpenClaw会扫描这些根目录下最多6层深的文件夹，查找其中的SKILL.md文件。
-   过滤与加载（filtering & Loading）：发现所有SKIL.md文件后，OpenClaw会根据以下规则进行过滤：
    -   元数据过滤：检查SKILL.md文件头部的YAML Frontmatter中的metadata.openclaw字段。例如，可以设置requires.bin（要求特定的二进制文件）、requires.env(要求特定的环境变量)或requires.config(要求特定的配置项)。如果不满足条件，该技能将不会被加载；
    -   智能体允许列表（agent allowlists）:可以在openclaw.json中为特定智能体配置skills列表，以精确控制它能使用哪些技能。
-   注入元数据（Injecting metadata）：所有通过过滤的skills，其元数据（主要是name和description）会被提取出来，格式化为能力清单。这个清单会被注入到系统提示词中，让模型知道当前可用的工具有哪些。注意，此时只有元数进入了上下文，SKILL.md的完整markdown正文并不会被加载

这个阶段在agent启动时，由loadSkillsEntries函数触发，会依次扫描多个预设的SKILL目录，以及多源扫描与优先级合并：OpenClaw会从多个来源加载Skills，并按固定优先级合并，高优先级会覆盖低优先级的同名Skill，核心扫描逻辑如下：

// src/agents/skills/workspace.ts
function loadSkillEntries(workspaceDir: string, opts?:{config?:OpenClawConfig}):SkillEntry[] {
    // 1. 从不同来源加载Skills
    const bundledSkills = loadSkills({dir:bundledSkillsDir,source:'openclaw-bundled'});
    const managedSkills = loadSkills({dir:managedSkillsDir,source:'openclaw-managed'});
    const workspaceSkills = loadSkills({dir:workspaceSillsDir,source:'openclaw-workspace'});

    // ... 可能还有其他的extraDir

    // 2. 按照优先级合并 bundled < managed < workspace < extra
    const merged = new map<string,Skill>();
    for(const skill of bundledSkills) merged.set(skill.name,skill);
    for(const skill of managedSkills) merged.set(skill.name,skill);
    for(const skill of workspaceSkills) merged.set(skill.name,skill);

    // ...

    // 3. 返回合并后的Skill列表，包含元数据
    return Array.from(merged.values()).map((skill) => ({
        skill,
        frontmatter: readSkillFrontmatterSafe({rootDir,skill.baseDir,filePath:skill.filePath}),
        metadata: resolveOpenClawMetadata(fontmatter),
        invocation:resolveSkillInvocationPolicy(fontmatter),
    }));
}

loadSkills函数是loadSkillEntries内部用于扫描单个目录的核心辅助函数，它的主要职责是发现SKILL.md文件并提取基本信息
//src/agents/skills/workspace.ts
function loadSkills(params:{dir:String;source:String}): Skill[] {
    const {dir,source} = params
    const skills: Skill[] = [];

    //1. 检查目录是否存在，不存在直接返回空数组
    if (!fs.existsSync(dir)) return skills;

    //2 遍历目录，最多深入6层，寻找SKILL.md文件（具体可以使用fast-glob）或类似的库
    const skillMdPaths = findFiles(dir,"**/SKILL.md",{maxDepth:6});

    for (const filePath of skillMdPaths) {
        // 3. 读取文件内容 并解析YAML fontmatter
        const content = fs.readFileSync(filePath,'utf-8');
        const {data: frontmatter,content: body} = parseFrontmatter(content);

        // 4.确定技能的唯一名称，优先使用frontmatter中的name，若缺失则使用文件夹名
        const name = frontmatter.name || path.basename(path.dirname(filePath));

        //5. 构建SKILL对象

        skills.push({
            name: name,
            description:frontmatter.descrption || "", //技能描述
            filePath:filePath,
            baseDir:ppath.dirname(filePath),
            source: source,
            body: body, //完整的markdown文件
            //..... 其他字段
        });
    }

    return skills;
}

function parseFrontmatter(fileContent:string)"{data:Record<string,any>;content:string} {
    // 1. 定义正则表达式用于匹配YAML Frontmatter
    //    模式解释: 
    //    ^---          匹配行首的 "---"
    //    \s*           匹配可能的空白字符
    //    \n?           匹配可能的换行符
    //    ([\s\S]*?)    非贪婪匹配任意字符（即 YAML 内容）
    //    \n?---\s*$    匹配以 "---" 结尾的行
    const frontmatterRegex = /^---\s*\n?([\s\S]*?)\n?---\s*$/;
    
    //2 尝试在文件内容匹配该模式
    const match = fileContent.match(frontmatterRegex);

    // 3. 如果匹配失败（文件没有yaml frontmatter）
    if（!match) {
        return {data:{},content:fileContent}
    }

    // 提取到匹配的YAML
    const yamlContent = match[1];

    // 获取yaml frontmatter之后剩余的markdown正文
    const bodyContent = fileContent.slice(match[0].length)

    // 调用parseYamlContent解析YAML
    data = parseYamlFrontmatter(yamlContent);

    return {data,content:bodyContent};
}

// src/agents/skills/frontmatter.ts
function parseYamlFrontmatter(yamlString:String):Record<string,any>{
    if (!yamlString || yamlString.trim() ===''){
        return {};
    }

    try{
        // 使用yaml库进行解析
        const parsed = yaml.load(yamlString,{
            strict:true, //严格模式，确保仅仅解析YAML 1.2
        });

        //确保解析结果是一个对象，否则返回空
        if（typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)）{
            return {};
        }

        return parsed;
    }catch(error){
        console.warn('failed to parse YAML frontmatter:${error.message}')
        return {};
    }
}

function readSkillFrontmatterSafe(params:{rootDir:string,filePath:string}):Record<string,any> {
    const {rootDir,filePath} = params;
    try{
        // 1. duqu SKILL.md文件内容
        const content = fs.readFileSync(filePath,'utf-8');

        // 2. 解析YAML frontmatter（位于文件开头处----分隔符之间）
        const frontmatter = parseYamlFrontmatter(content);

        // 返回解析后的元数据
        return frontmatter || {}
    }catch(error){
        // 4. 错误处理
        logger.warn('failed to parse frontmatter for ${filePath}:${error.message}')
        return {}
    }
}

// 解析OpenClaw 运行时元数据
function resolveOpenClawMetadata(frontmatter:Record<string,any>):OpenClawMetadata{
    // 1. 安全提取metadata.openclaw对象
    const raw = frontmatter?.metadata?.openclaw || {};

    // 2. 解析并规范化各个字段
    return {
        // 环境变量要求，技能所必须的环境变量列表
        requiresEnv: Array.isArray(raw.requires?.env) ? raw.requires.env : [],
        requiresBins: Array.isArray(raw.requres?.bins) ? raw.requires.bin : [],
        requiresConfigs: Array.isArray(raw.requires?.configs) ？ raw.requires.configs : [],

        primaryEnv:raw.primaryEnv || null,
        // ...其他字段凭据

        emoji:raw.emoji || null,
        os:Array.isArray(raw.os) ? raw.os :[],
        always:raw.always === true,
     };
}

// 解析调用策略,决定了技能在什么条件下可以被Agent调用
function resolveSkillInvocationPolicy(frontmatter:Record<string,any>): SkillInvocationPolicy {
    // 1. 从 frontmatter中提取相关字段，例如invocation,allowed,或command-dispatch等
    const invocationConfig = frontmatter.invocation || frontmatter["command-dispatch"] || {};

    // 2.解析策略
    return {
        //调用模式
        mode: invocationConfig.mode || "tools",
        // 命令工具，如mode是command,指定要执行的命令[reference:22]
        commandTool:invocationConfig["command-tool"] || null,
        //是否允许:一个布尔值或更复杂的条件表达式
        allowed: invocationConfig.allowed !== false, //默认允许
        // ...其他策略字段
    };
}

#### 2. 读取SKILL.md与元数据提取
扫描时，每个SKill目录下的SKILL.md文件会被读取，但读取的并非全文，而是通过解析YAML Frontmatter来提取name,description等元数据

#### 3. 元数据过滤
收集到的Skill会根据其元数据进行过滤，例如检查metadata.openclaw字段中定义的环境依赖是否满足，不满足的Skill会被排除。

####  4. 如何解决Skills文件内容被修改后的缓存问题？
这是社区被解决掉的问题，早期存在一个会话级快照(skillsSnapshot)缓存，导致已经存在的会话无法感知到技能文件的变更。
现在的解决方案是一个双层失效机制：
-   文件变更监听（file watcher）:OpenClaw的ensureSkillsWatcher函数会使用chokidar库来监听技能目录。当SKILL.md问价发生变更时，监控器会触发事件。这个事件会主动使缓存失效（bumpSkillsSnapshotVersion），强制会话在下一轮对话时重新构建技能快照；
    -   关键配置：可以通过skills.load.watch开关此功能，并通过skills.load.watchDebounceMs调整防抖时间长短。
-   配置/目录变更失效（Configuration Change）:修复方案还处理了另一种情况：当你修改了openclaw.json，例如添加了新的技能目录（skills.load.extraDirs）,即使没有文件被修改，技能列表也发生了变化。ensureSkillsWatcher函数会检测到“监控目录”发生了变化，并同样调用bumpSkillsSnapshotVersions来使现有会话缓存失效。这确保了新增的技能目录立法被所有会话感知，而无需重启Gateway或开启新的会话。


### 2.核心执行 runEmbeddedAgent的详细步骤
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

-   <B加载技能SKILLS，系统会加载智能体配置中定义的skills快照，并将其注入到提示词中，skills是智能体可以执行的具体功能模块

##### 1.定义哪些文件需要被读取
OpenClaw在 src/agent/workspace.ts中，会先明确定义所有需要加载的引导文件名，这构成了文件发现的基础：源码在src/agents/workspace.ts中：
export const DEFAULT_AGENTS_FILENAME = "AGENTS.md"
export const DEFAULT_SOUL_FILENAME = "SOULE.md"
export const DEFAULT_TOOLS_FILENAME = "TOOLS.md"
export const DEFAULT_IDENTIFY_FILENAME = "IDENTIFY.md"
export const DEFAULT_USER_FILENAME = "USER.md"
export const DEFAULT_HEARTBEAT_FILENAME = "HEARTBEAT.md"
export const DEFAULT_BOOTSTRAP_FILENAME = "BOOTSTRAP.md"
export const DEFAULT_MEMORY_FILENAME = "MEMORY.md"

##### 2. 核心读取逻辑是 loadWorksppaceBootstrapFiles 函
这是实际执行文件读取的函数，它会按照固定顺序扫描工作区目录，并读取每个已定义的文件：
async function loadWorkspaceBootstrapFiles(workspaceDir: string) {
    //1. 定义要读取的文件名列表（顺序固定）
    const fileNames = [
        DEFAULT_IDENTIFY_FILENAME,
        DEFAULT_SOUL_FILENAME,
        DEFAULT_AGENTS_FILENAME,
        ... // 其他文件
    ];

    const results = [];
    for (const fileName of fileNames) {
        const filePath = path.join(workspaceDir,fileName);

        // 通过readFileWithCache读取文件，获得内容和元数据
        const result = await readFileWithCache(filePath);
        results.push({
            path: filePath,
            content: result.content, // 文件内容
            exists: result.exists,
            mtimeMs: result.mtimeMs, //用于缓存校验
            ....
        });
    }
    return results;
}

##### 3. 带缓存的文件读取：readFileWithCache
loadWorkspaceBootstrapFiles并不直接使用fs.readFile，而是通过readFileWithCache函数来读取，这是一个更底层、基于文件修改的时间的缓存机制。

const workspaceFileCache = new Map(); 

async function readFileWithCache(fielPath: string) {
    // 1. 获取文件最新的修改时间
    const stats = await fs.stat(filePath)
    const mttimeMs = stats.mtimeMs;

    // 2. 检查缓存中是否有该文件，且修改时间是否一致
    const cached = workspaceFileCache.get(filePath)
    if (cached && cached.mtimeMs == mtimeMs) {
        return cached; //存在且未修改
    }

    // 3. 文件变动或首次读取
    const content = await fs.readFile(filePath,'utf-8')
    // 4. 更新缓存
    workspaceFileCache.set(filePath,{content,mtimeMs,exists:true});
    return {content,mtimeMs,exists:true}
}

##### 4. 内容是如何被管理： getOrLoaadBootstrapFiles与缓存
loadWorkspacBootstrapFiles和readFileWithCache构成了一套基于文件的缓存，但它本身是“无状态”的，每次调用都会重新扫描所有文件。为了提升性能，OpenClaw在其上又构建了一层会话级（Session-Level）的缓存机制，这个缓存由getOrLoadBootstrapFiles函数管理：
//在代码文件：src/agents/bootstrap-cache.ts

const sessionCache = new Map()

async function getOrLoadBootstrapFiles(params) {
    const sessionKey = params.sessionKey

    // 1. 检查会话缓存是否有快照，L1 级缓存
    const cachedSnapshot = sessionCache.get(sessionKey);
    if (cachedSnapshot) {
        // 2. 如果有，直接返回，不再读取磁盘
        return cachedSnapshhot;
    }

    // 2. 缓存未命中
    const files = await loadWorkspaceBootstrapFiles(params.workspaceDir);

    //将结果缓存入会话缓存
    sessionCache.set(sessionKey,files);
    return files;
}

以上的代码存在问题：1. 在sessionCache中缓存命中，但是实际文件已经被修改了，未被加载
OpenClaw社区最终的改进方案是将sessionCache直接移除，而是直接使用loadBootstrapFiles构建的L2级缓存

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
