
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
    |  1.检查是否斜杠命令 -> 否                                         |
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

#### 5. 验证模型与认证

    //当前coding-agent 由 ModeRuntime统一提供模型和认证能力
    const model = this.modelRuntime.getModel(provider,modelId);
    if (!model) throw new Error("unknown model: ${provider}/${modelId}");

ModelRuntime会把运行时凭证、持久化凭证、Provider配置和pi-ai的认证策略组合起来：
- 1. runtime覆盖 (--api-key)
- 2. auth.json中保存的API Key/ OAuth token
- 3. provider 配置中的apiKey (如auth.json的env覆盖)
- 4. 环境变量（通过pi-ai envApiKeyAuth）

#### 6. 检查是否需要压缩
    const lastAssistant = this._findLastAssistantMessage();
    if (lastAssistant && (await this._checkCompaction(lastAssistant,false))) {
        await this.agent.continue();
        while (await this._handlePostAgentRun()) {
            await this.agent.continue();
        }
    }
    
压缩的触发时机有：
- 手动：用户输入 /compact
- 阈值：上下文token数超过设定的阈值
- 溢出：LLM返回 context overflow 错误
压缩事件还会携带 reason (manual/threshold/overflow) 和willRetry,让扩展区分手动压缩、阈值压缩与溢出重试。

#### 7.构建消息并发送
    message = [
        {
            role: 'user',
            content:'[{type: 'text', text: expandedText},...(currentImage ?? [])]
            timestamp: Date.now(),
        },
    ];
    await this._runAgentPrompt(messages);


### 阶段C：Agent启动

文件：packages/coding-agent/src/core/agent-session.ts
_runAgentPrompt -> packages/agent/src/agent.ts -> packages/agent/src/agent-loop.ts

    private async _runAgentPrompt(messages: AgentMessage[]) : Promise<void>{
        try{
            await this.agent.prompt(messages);
            while(await this._handlePostAgentRun()){
                await this.agent.continue();
            }
        }finally{
            this._flushPendingBashMessages();
        }
    }

Agent.prompt() 将输入归一化为AgentMessage[],然后调用runPromptMessages()；

    private async runPromptMessages(messages: AgentMessage[]):Promise<void>{
        await this.runWithLifecycle(async (signal) => {
            await runAgentLoop(
                messages,
                this.createContextSnapshot(),
                this.createLoopConfig(),
                (event) => this.processEvents(event),
                signal,
                this.streamFn,
            );
        });
    }
关键：createLoopConfig()中配置的streamFn是调用pi-ai的入口。在coding-agent中，它通常闭包捕获ModelRuntime，再调用modelRuntime.streamSimple()；
Agent Loop不需要知道凭证存放在哪里。

### 4.阶段D:Agent Loop核心循环
#### 1. 核心循环

文件:packages/agent/src/agent-loop.ts
    async function runLoop(
        initialContext:AgentContext,
        newMessages: AgentMessage[],
        initialConfig:AgentLoopConfig,
        signal:AbortSignal | undefined,
        emit: AgentEventSink,
        streamFn?: StreamFn,
        ): Promise<void> {
        let curentContext = initialContext;
        let pendingMessages: AgentMessage[] = (await config.getSteeringMessages?.()) || [];

        while(true){
            let hasMoreToolCalls = true;
            while(hasMoreToolCalls || pendingMessages.length > 0) {
                if (!firstTurn) await emit({type: 'turn_start'});

                //注入pending message
                if (pendingMessages.length > 0){
                    for (const message of pendingMessages){
                        currentContext.messages.push(message);
                        newMessages.push(message);
                    }

                    pendingMessages = [];
                }

                //调用LLM
                cosnt message = await streamAssistantResposne(currentContext,config,signal,emit,streamFn);
                newMessages.push(message);

                if (message.stopReason == 'error' || message.stopReason == 'aborted') {
                    await emit({type:'turn_end',message,toolResults:[]}); //发出事件
                    await emit({type:'agent_end',messages: newMessages}); //发出事件
                    return;
                }

                // 提取tool calls
                const toolCalls = message.content.filter((c) => c.type == 'toolCall');
                hasMoreToolCalls = false;

                if (toolsCalls.length > 0){
                    const executedToolBatch = await executeToolCalls(currentContext,message,config,signal,emit);
                    hasMoreToolCalls = !executeToolBatch.terminate;
                    for (const result of executeToolBatch.messages){
                        currentContext.messages.push(result);
                        newMessages.push(result);
                    }
                }

                await emit({type:'turn_end',message,toolResults:executedToolBatch.messages});
            }

            // 检查follow -up
            const followUpMessages = (await config.getFollowUpMessages?.()) || [];
            if (followUpMessages.length > 0){
                pendingMessages = followUpMessages;
                continue;
            }

            break;
        }

        await emit({type:'agent_end',messages:newMessages});
    }

    async func steamAssistantResponse(
        context: AgentContext,
        config: AgentLoopConfig,
        signal: AbortSignal | undefined,
        emit: AgentEventSink,
        streamFn?: streamFn,
        ): Promise<AssistantMessage>{
        const llmMessages = await config.convertToLlm(messages);
        const llmContext: Context = {
            systemPrompt: Context.systemPrompt,
            messages: llmMessages,
            tools: context.tools,
        };

        // 通过ModelRuntime解析并认证调用Provider
        const response = await streamFunction(config.model,llmContext,{signal});

        for await (const event of response) {
            switch (event.type){
                case 'start':
                case 'text_delta':
                case 'thinking_delta':
                case 'toolcall_delta':
                    partialMessage = event.partial;
                    context.messages[context.messages.length - 1] = partialMessage;
                    await emit({type:'message_update',assistantMessageEvent:event,message:{...partialMessage}});
                    break;
                case 'done':
                case 'error':

            }
        }

        return partialMessage!;
    }

#### 2. executeToolCalls详解

    LLM返回ToolCall {name:"read",arguments:{path:"package.json"}}
        |
        |
    executeToolCalls()
        |
        | -> 1.查找工具定义
        | -> 2.validateToolArguments() - typebox schema校验
        | -> 3.发出tool_call_start事件
        | -> 4.执行工具 handler
        |      read工具；fs.readFileSync(path,'utf-8')
        | -> 5.发出tool_result事件
        | -> 6.返回ToolResultMessage

## 3 循环终止条件
- LLM正常回复完成 stopReason == "stop"  行为= 内层循环退出
- LLM调用工具   stopReason == "toolUse" 行为= 继续内层循环
- 超过最大的token stopReason == "length" 行为=内层循环退出
- 发生错误  stopReason == "error" 行为 = 直接return
- 用户中断(ctrl+c) stopReason == "aborted" 行为=直接return
- 用户输入steer  stopReason == -- 行为 = 注入后继续
- 用户输入follow-up stopReason == -- 行为 = 外层循环继续

## 4 关键概念总结
AgengSession 业务逻辑中枢，处理消息预处理 agent-session.ts
Agent 智能体运行时，管理状态和生命周期，agent.ts
runAgentLoop 核心循环，LLM -> 工具 -> 循环 agent-loop.ts
streamAssistantResponse LLM 调用入口，处理流式事件 agent-loop.ts
executeToolCalls 工具执行，验证->执行->返回结果 agent-loop.ts
Steer Agent工作中注入消息，当前工具完成后生效 agent-session.ts
Follow-up Agent完成后排队的新消息 model-runtime.ts
事件驱动 所有状态变化通过事件通知TUI， emit()调用