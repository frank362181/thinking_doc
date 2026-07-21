这里是理解Pi运行机制的第一道门槛，当在终端输入pi 并按下Enter后，一段精密的链条开始运行，本文的代码基于 Pi 0.80.10为基础。

## 1 全景图

    pi hello world
        |
        |- 1. Shell解析命令，查找可执行文件
        |
        |- 2. Node.js 启动cli.ts
            |- shebang指定node
            |- process.title = "pi" // 设置进程名称
            |- main(process.argv.slice(2)) // 启动主流程
        |
        |- 3. main() 解析参数、组装服务
            |- parseArgs(args) //解析CLI参数
            |- resolveAppModel() -> "interactive"
            |- 项目信任决策(project trust)
            |- createAgentSessionServices() //创建服务
            |- createAgentSessionRuntime() //组装runtime
            |- InteractiveMode.run() //启动 TUI
        |
        |- 4. InteractiveMode.run() //启动 TUI
            |- new TUI(new ProcessTerminal()) //创建 TUI 实例
            |- init() //构建UI布局
            |- run() //进入主循环

当前主流程的两个关键边界是 项目信任（Project Trust）和 Runtime 工厂：同一个createRuntime 工厂会被复用于 /new、 /resume、/fork等会话切换场景；模型于认证则由 ModelRuntime 统一提供。

## 2 代码详解
### 1. 阶段 1 ：CLI入口 （cli.ts）

文件位置：packages/coding-agent/src/cli.ts

    import {main} from './main.ts';
    process.title = APP_NAME; // 在 ps/top 中显示为 "Pi"
    process.env.PI_CONFIG_AGENT = 'true'; // 标记这是coding-agent进程
    configurreHttpDispatcher(); // 配置HTTP请求

    main(process.argv.slice(2)); //传入去掉node/cli的参数

这个文件仅仅做了3件事情：
- 设置进程名：在 ps aux|grep pi中能看到；
- 标记环境变量--子进程（bash工具）可以检测自己是否在Pi中运行
- 启动主流程--cli.ts本身不做事，只是负责启动 main()

### 2. main()参数解析与服务组装

文件：packages/coding-agent/src/main.ts

#### 1. 参数解析

const parsed = parseArgs(args); parseArgs()将所有的CLI参数解析为一个Args对象：
    
    interface Args {
        model?: string; //model或provider
        thinking:? string; // thinking level
        session?: string; // session >path|id>
        continue?: boolean; // -c 继续最近会话
        resume?: boolean; // -r 浏览选择历史会话
        noSession:? boolean; // --no-session 不持久化
        help?: boolean; // -- help
        version?: boolean; //-- version
        print?: boolean; // -p "prompt" 非交互模式
        mode?: 'rpc' | 'json'; // --mode
        verbose?: boolean; // --verbose
        apiKey?: string; // --api-key(runtime 覆盖)
        ...    
    }

#### 2. 决定运行模式
    lep appMode = resolveAppMode(parsed,process.stdin.isTYY);
    function resolveAppMode(parsed: Args, stdinIsTYY: boolean): AppMode {
        if (parsed.mode === 'rpc') return 'rpc'; // RPC模式（进程集成）
        if (parsed.mode === 'json') return 'json'; // JSON事件流模式
        if (parsed.print || !stdisTYY) return 'print'; // 一次性输出
        return 'interactive'; // 默认交互模式
    }
    resolveAppMode根据解析出来的结果来确定运行的模式，4中模式的区别：
    - interactive: 直接Pi,日常使用，TUI界面；
    - print：pi -p "prompt" 一次性问答， 适合脚本；
    - json：pi --mode json 输出结构化JSON事件
    - rpc pi --mode rpc 作为其他程序的子进程

#### 3. 项目信任 

在加载醒目本地.pi目录、扩展、资源之前，main()会调用resolveProjectTrusted();项目信任决策：
项目信任决策：
    |- 检查trust store(~/.pi/agent/trust.json)是否已记录该cwd的信任决策；
    |- 如果没有，检查是否有需要信任的项目资源（.pi、AGENTS.md、。agents/skills等）；
    |- 触发project_trust扩展事件（仅限user/global/CLI扩展）
    |- 必要时弹出 TUI 选择器询问用户

只有项目被信任后，才会继续加载项目本地扩展 .pi配置参见[03-项目认证机制.md]()。

#### 4. 创建服务 createAgentSessionService

文件：packages/coding-agent/src/core/agent-session-services.ts

    const services = await createAgentSessionServices({
        agentDir,
        cwd,
        settingsManager,
        modelRuntime,
        ...
    });

    这里创建并链接所有核心服务：
    ┌─────────────────────────────────────────────┐
    │          AgentSessionServices               │
    │                                             │
    │  ┌────────────────┐  ┌───────────────────┐  │
    │  │ SettingsManager│  │ ModelRuntime      │  │
    │  │ (全局/项目设置)  │  │ (模型/认证/刷新)  │  │
    │  ├────────────────┤  ├───────────────────┤  │
    │  │ ResourceLoader │  │ Diagnostics       │  │
    │  │ (扩展/Skill/提示词) │ (诊断信息)        │  │
    │  └────────────────┘  └───────────────────┘  │
    └─────────────────────────────────────────────┘

#### 5. 创建 Runtime （createAgentSessionRuntime）

文件：packages/coding-agent/src/core/agent-session-runtime.ts； main()函数构造一个createRuntime工厂函数，然后传给createAgentSessionRuntime；
    
    const runtime = await createAgentSessionRuntime({
        cwd: sessionManager.getCwd(),
        agentDir,
        sessionManager,
    });
关键设计：同一个createRuntime工厂会被保存到AgentSessionRuntime中，后续 /new、/resume、/fork导入会话时都会复用它重新创建服务与Session。
    
    export async function createAgentSessionRuntime(
        createRuntime: CreateAgentSessionRuntimeFactory,
        options: {cwd: string; agentDir: string; sessionManager: SessionManager; sessionStartEvent?: SessionStartEvent},
        ):Promise<AgentSessionRuntime> {
        const result = await createRuntime(options);
        return new AgentSessionRuntime(
            result.session,
            result.services,
            createRuntime,
            result.diagnostics,
            result.modelFallbackMesssage,
        );
    }

### 3. InteractiveMode启动 TUI

文件：packages/coding-agent/src/modes/interactive/interactive-mode.ts

#### 1. 构造函数

    this.ui = new TUI(new ProcessTerminal(),settingsManager.getShowHardwareCursor());

ProcessTerminal 接管终端：ProcessTerminal初始：

    -> process.stdin.setRawMode(true) // 进入 raw mode: 逐按键读取
    -> process.stdin.resume()         // 恢复 stdin 流
    -> write("\x1b[?1049h")             // 切换到备用屏幕缓冲区
    -> write("\x1b[?251")               // 隐藏光标
    -> write("\xb[?2004h")              // 启用 bracketed paste

raw mode时终端变成的核心：正常模式下终端按行缓冲，raw mode下每个按键立即发送，TUI才能实时响应。

#### 2. init() 构建UI布局
    
    async init(): Promise<void> {
        this.registerSignHandlers();
        
        //确保 fd 和 rg工具可用（自动下载）
        const [fdPath] = await Promise.all([ensureTool("fd"),ensureTool("rg")]);
        
        // 从顶到底构建布局
        this.ui.addChild(this.headerContainer);
        this.ui.addChild(this.chatContainer);
        this.ui.addChild(this.pendingMessagesContainer);
        this.ui.addChild(this.statusContainer);
        this.ui.addChild(this.widgetContainerAbove);
        this.ui.addChild(this.editorContainer);
        this.ui.addChild(this.widgetContainerBelow);
        this.ui.addChild(this.footer);

        this.ui.setFocus(this.editor);
        this.setupKeyHandler();
        this.setupEditorSubmitHandler();
        this.ui.start(); // 启动 TUI 渲染循环
    }

#### 3. ui.start() 启动渲染循环

文件：packages/tui/src/tui.ts

    private handleInput(data: string): void {
        //处理 OSC 11 终端背景色恢复、颜色方案变化等；
        if (this.consumeOsc11BackgroundResponse(data)) return;
        if (this.consumeTerminalColorSchemeReport(data)) return;

        // 分发给 input listener
        for (const listener of this.inputListeners) {
            const result = listener(current);
            if (result?.consumed) return;
        }

        // 分发给聚焦组件
        this.focusedComponent?.handleInput?.(data);
    }

    渲染循环
    
    private scheduleRender(): void {
        const elapsed = performance.now() - this.lastRenderAt;
        const delay = Math.max(0,TUI.MIN_RENDER_INTERVAL_MS - elapsed);
        this.renderTimer = setTimeout(() => {this.doRender();},delay);
    }
    
    差分渲染：每帧收集所有组件的render(width)输出，与上一帧对比，只输出变化的行。

#### 4. 主循环等待输入

文件：packages/coding-agent/src/modes/interactive/interactive-mode.ts

    async run(): Promise<void> {
        await this.init();
        
        // 异步启动任务
        checkForNewPiVersion(this.version);
        this.checkForPackageUpdates();
        this.checkTmuxKeyboardSetup();

        if(initialMessage) {
            await this.session.prompt(initialMessage);
        }

        // 主循环
        while(true) {
            const userInput = await this.getUserInput();
            try{
                await this.session.prompt(userInput);
            }catch(error){
                this.showError(errorMessage);
            }
        }
    }

    getUserInput() 用一个Promise挂起等待编辑器回调：
    
    async getUserInput(): Promise<string> {
        return new Promise((resolve) => {
            this.onInputCallback = (text: string) => {
                this.inInputCallback = undefined;
                resolve(text);
            };
        });
    }

    当用户按Enter时，编辑器调用回调，主循环继续，调用 session.prompt(userInput)。

## 3. 关键概念总结
- raw mode        终端逐按键读取，不按行缓冲       terminal.ts
- 差分渲染         只更新变化的行，减少闪烁          tui.ts
- 备用屏幕         退出Pi后恢复原终端内容           terminal.ts
- bracketed paste 区分键盘输入和粘贴内容    terminal.ts
- Component 接口   所有UI组件的基类        tui.ts
- Runtime工厂      复用于 /new /resume /fork agent-session-runtime.ts
- 项目信任          加载项目资源前的用户确认      project-trust.ts / trust-manager.ts