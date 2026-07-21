## 1.执行智能体 agentCommand
该函数是openclaw的核心运行代码，CLI输入openclaw agent -agent <agentId> -message "message"就会运行该函数。

参数和配置就绪后，执行流程进入到agentCommand函数，agentCommand函数的调用流程如下图描述所示：
用户执行命令 openclaw agent --agent-id -> CLI 解析命令 -> 调用agentCommand函数 -> agentCommand准备参数 -> 调用loadSkillEntries扫描并加载技能元数据 -> 构建技能快照 Skills Snapshot -> 调用runEmbeddedAgent执行核心Agent循环 -> 组装system prompt注入技能snapshot -> 开始与模型交互

### 1 读取SKILLS：loadSkillEntries函数
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

### 3 buildAgentSystemPrompt
该函数的作用是构建system prompt。先来讲解以下system prompt的组成，system prompt由 固定架构 和 动态内容两部分组成，从system_prompt.md中的system prompt示例中可见，从开头的You are...到 ## Reasoning 部分属于固定架构，而 # Project Context及其后续的内容则是动态加载的。

#### 1 System Prompt的组成
System Prompt各个模块的作用：
-   身份申明：You are ... 是告诉模型当前应用的角色定义，说明其身份和运行环境；
-   工具清单（## Tooling）:列出所有可用工具机器功能描述，这是告诉模型所拥有的 “武器库”；
-   工具调用风格（## Tool Call Style）：指导模型如何使用工具，例如并行调用、错误处理等；
-   安全准则（## Safety）:设定模型调用的行为边界和底线；
-   技能列表（## Skills）:以<available_skills>格式列出所有可用的技能，让模型知道有哪些专业知识扩展包可用
-   OpenClaw 控制与更新（## OpenClaw Control && ## OpenClaw Self-Update）: 指导模型通过gateway、config.*等专用工具管理OpenClaw本身；
-   工作区与文档（## Workspace ## Documentation ## Workspace Files）：设定工作区目录和参考文档位置
-   RunTime（## Runtime）：运行时信息
-   Project Context（## Project Context）:这是动态注入的部分，包含AGENTS.md、SOUL.md等引导文件的内容，TOOLS.md的内容就在于此

#### 2 system prompt构建函数：buildAgentSystemPrompt
OpenClaw的系统提示词是由src/agents/system-prompt.ts中的buildAgentSystemPrompt()函数生成。该函数是一个“纯渲染器”，负责将各种输入拼装成最终的提示词：
export function buildAgentSystemPrompt(params:{
    workspaceDir: string;
    toolName?: string[];
    skillsPrompt?: string; //由skills系统生成的XML块
    extraSystemPrompt?: string;
    userTimeZone?: string;
    promptMode?: PromptMode; // full | minimal | none
    contextFiles?: EmbeddedContextFile[] ; //引导文件内容
    ... // 更多参数
}) {
    // 1. 根据 promptMode 决定包含哪些模块
    if (promptMode == "none") {
        return "You are a personal assistant running inside OpenClaw."
    }

    // 2. 按顺序冰洁各个模块
    const lines = [
        "You are a personal assistant running inside OpenClaw.",
        "",
        "## Tooling",
        buildToolingSection(params.toolNames),
        "",
        "## Safety",
        SAFETY_GUIDELINES,
        "",
        //... 更多参数
    ];

    //3. 注入skills
    if (params.skillsPrompt){
        lines.push("## skills", params.skillsPrompt);
    }

    // 4. 注入项目上下文
    if (params.contextFiles?.length) {
        lines.push("## Project Context");
        for (const file of params.contextFiles){
            lines.push('## ${file.flename}',file.context);
        }
    }

    return lines.filter(Boolean).join("\n");
}

buildAgentSystemPrompt()的调用是在Agent运行的准备阶段，具体流程如下：
-   1. 用户触发：用户通过CLI或gateway发起对话；
-   2. 进入agentCommand：命令入口函数被调用，负责整个Agent执行的生命周期；
-   3. 准备上下文：在执行核心的runEmbeddedAgent函数之前，agentCommand会进行准备工作：
    -   a.调用loadWorkspaceBootstrapFiles()读取AGENTS,SOUL,TOOLS等引导文件
    -   b.调用技能加载系统，生成skillsPrompt（即<available_skills>）的XML块；
-   4.调用buildAgentSystemPrompt():将所有准备好的数据（工作区路径、工具列表、技能提示、引导文件内容等）作为参数，调用此函数生成完整的System Prompt
-   5.注入并执行：生成的System Prompt与用户消息一起发送给大模型，开始推理和工具调用循环