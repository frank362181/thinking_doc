
## 1. 全景图
    用户在编辑器中输入“帮我重构这个函数”并按 Enter
        |
    |————————————————————————————————————————————————————————————————|
    | 阶段A：TUI -> AgentSession                                      |
    | InteractiveMode.run()                                          |
    |   |-> getUserInput() -> "帮我重构这个函数"                        |
    |   |-> session.prompt(userInput)                                |
    |________________________________________________________________|
        |
        |
    |_________________________________________________________________
    | 阶段B：消息预处理 (AgentSession.prompt)                            |
    |  1.检查是否有谢康命令 -> 否                                         |
    |  2.扩展事件触发 (扩展可拦截 / 修改输入)                               |
    |  3.展开 skill / prompt template                                  |
    |  4.通过ModeRuntime 准备模型和认证                                   |
    |  5.检查是否需要压缩 （compact)                                      |
    |  6.构建AgentMessage[]                                            |
    |  7._runAgentPrompt(messages)                                    |
    |_________________________________________________________________|
        |
        |
    ┌─────────────────────────────────────────────────────────-┐
    │ 阶段 C：Agent 启动 (Agent.prompt)                          │
    │   normalizePromptInput() → AgentMessage[]                │
    │   runPromptMessages(messages)                            │
    │     → runWithLifecycle() → runAgentLoop()                │
    └─────────────────────────--───────────────────────────────┘
        |
        |
    ┌─────────────────────────────────────────────────────────┐
    │ 阶段 D：★ Agent Loop（核心循环）                           │
    │                                                         │
    │   while (true) { // 外层：follow-up 循环                  │
    │     while (hasMoreToolCalls || pendingMessages) {       │
    │                                                         │
    │       ① 注入 pending messages（steer/follow-up）         │
    │       ② streamAssistantResponse()                      │
    │          → 通过 Models 运行时调用 LLM                     │ 
    │       ③ 检查 stopReason                                 │
    │          → error/aborted → 退出                         │
    │       ④ 提取 tool calls                                 │
    │          → 有 → executeToolCalls()                      │
    │          → 无 → hasMoreToolCalls = false                │
    │     }                                                   │
    │                                                         │
    │     检查 follow-up messages                              │
    │     → 有 → 设为 pending → continue 外层循环               │
    │     → 无 → break，退出                                   │
    │   }                                                     │
    └─────────────────────────────────────────────────────────┘

## 2. 代码详细分析
### 1. 阶段 A：TUI传递输入

文件: packages/coding-agent/src/modes/interactive/interactiveactive-mode.ts

    async run(): Promise<void> {
        await this.init()
        
        //主循环
        while(true) {
            const userInput = await this.getUserInpput(); // 等待用户输入
            try {
                await this.session.prompt(userInput);
            }catch(error){
                this.showError(errorMessage);
            }
        }
    }

getUserInput()用Promise挂起，编辑器提交时resolve。

### 2.阶段B：消息处理

文件：packages/coding-agent/srccore/agent-session.ts
这是输入到LLM之间最重要的关卡。prompt()和方法对输入做多层处理：

#### 1. 斜杠命令
    if (expandPromptTemplates && text.startsWith('/')) {
        const handled = await this._tryExecuteExtensionCommand(text);
        if (handled) return;
    }

以 / 开头的输入先尝试执行扩展命令；若未被处理，再作为普通消息发送。

#### 2. 扩展事件拦截
    if (this._extensionRunner.hasHandlers('input')) {
        const inputResult = await this._extensionRunner.emitInput(
            currentText,
            currentImages,
            options?.source ?? 'interactive', 
            this.isStreaming ? options?.streamingBehavior : undefined,
        );

        if(inpuResult.action === 'handled') return;
        if (inputResult.action === 'transform') {
            currentText = inputResult.text;
            currentImages = inputResult.images ?? currentImages;
        }
    }

扩展可返回三种动作：
- pass：跳过，继续下一个扩展或默认流程
- handled：扩展已处理，不再发给LLM
- transform：修改输入后继续处理

#### 3.skill和prompt template展开
    if (expandPromptTemplate){
        expandedText = this._expandSkillCommand(expandedText);
        expandedText = expandPpromptTemplate(expandedText,[...this.promptTtemplates]);
    }

#### 4.流式处理检查
    if (this.isStreaming){
        if (options.streamimgBehavior === 'followUp'){
            await this._queueFollowUp(expandedText,currentImages);
        }else{
            await this._queueSteer(expandedText,curentImages);
        }
        return;
    }

Steer和followUp的区别
- Steer： Agent正在工作中输入，当前工具执行完成后、下一次LLM调用前注入消息；
- FollowUp：Agent正在工作中输入，Agent完全完成后作为新问题排队。
