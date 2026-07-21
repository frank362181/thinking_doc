## 1. 历史消息的加载

OpenClaw 的runEmbeddedAgent是实现与LLM的真正的入口函数，该函数清晰的分为三个层次：入口调度、执行尝试和核心调用和工具执行。
而历史消息的加载发生在第二层：执行尝试阶段，而且每次调用该函数时都会加载历史消息，其核心流程是：runEmbeddedAttempt ->  createAgentSession -> SessionManager.buildSessionContext -> 从JSONL文件中读取历史消息，即在SessionManager.buildSessionContext函数中实现从JSONL文件中读取历史消息。

### 1 如何加载历史

buildSessionContext方法来构建发给LLM的完整的消息列表，这个方法的核心任务就是从持久化存储中读取历史消息：
    class AgentSession {
        constructor (sessionManager: SessionManager) {
            this.sessionManager = sessionManager;
        }

        async buildSessionContext(userMessage: string) {
            // 1. 从SessionManager加载历史消息
            const history = await this.sessionManager.getMessages(this.sessionKey);

            // 2.构建完整的消息列表 [系统提示词,...历史消息,当用用户消息]
            const messages = [
                {role:'system',content: this.systemmPrompt},
                ...history,
                {role,'user',content:userMessage}
            ];

            return messages;
        }
    }

### 2 存储格式：JSONL对话转录

OpenClaw将每个会话的完整历史（包括消息、工具调用及结果）以JSONL（JSON Lines）格式存储在本地。
- 存储位置：通常位于~/.openclaw/agents/main/sessions/目录下；
- 文件格式：每一行是一个JSON对象，代表一条消息记录
    {"role":"user","content":"你好","timestamp":12345678}
    {"role":"assistant","content":[{"type":"text","text":"你好！有什么可以帮你的？"}],"timestamp":12345667}
    {"role":"toolResult","toolName":"bash","result":"ok","timestamp":12345678}

### 3. 历史消息加载

这里所讲的历史数据加载是指提供给WEB展示使用的加载历史数据的展示，这里是一个RESTful API接口。

### 4. 历史消息的实际加载

历史消息的实际加载执行者是SessionManager的buildSessionContext函数，它的工作就是从当前会话的”叶子节点“开始，通过parentId指针向上回溯，构建一条完整的对话路径：

    // packages/coding-agent/src/core/session-manager.ts (概念性示意)
    class SessionManager {
        buildSessionContext() {
            // 1. 从叶子节点开始，通过 parentId 回溯构建路径
            const path: SessionEntry[] = [];
            let current = leaf;
            while (current) {
            path.unshift(current);
            current = current.parentId ? byId.get(current.parentId) : undefined;
            }

            const messages: AgentMessage[] = [];
            // 2. 根据是否存在压缩点，采用不同策略处理
            if (compaction) {
                // 有压缩点：插入摘要 + 关键消息
                messages.push(createCompactionSummaryMessage(compaction.summary));
                // ... 从 firstKeptEntryId 到 compactionIdx 的关键消息
            } else {
                // 无压缩点：直接转换所有消息
                for (const entry of path) {
                    if (entry.type === "message") {
                    messages.push(entry.message);
                    }
                    // ... 处理其他类型 (custom_message, branch_summary)
                }
            }
            return messages;
        }
    }

### 5. 提交给LLM：OpenClaw是如何组装的？

OpenClaw提交给LLM的messages数组有三部分构成：
- System Prompt（系统提示词）：由OpenClaw在每次运行时动态构建，内容完全由其掌控。构建过程分为三层，最终生成的System Prompt包含工具定义、执行规则、安全准则、工作区信息、当前时间等结构化内容。
- 对话历史（conversation history）：从JSONL会话文件中加载的历史消息，以及本次对话中新增的消息；
- 工具调用与结果（Tool Calls & Results）：Agent在ReAct循环中产生的工具调用请i去机器返回结果。
此外，提交的内容还包括注入的工作区文件、附件（图表、音频等），以及OpenClaw自动添加的压缩摘要和修剪产物等。

### 6. 如何判断上下文是否超限？

OpenClaw是通过主动预估和被动检测两种方式来感知上下文是否超限。
- 主动预估（Pre-flight Check）:在每次向LLM发送请求前，OpenClaw会估算当前上下文的Token总数，这种估算会考虑输入提示和请求的max_tokens（输出上限），
  确保估算输入Token数 + 请求的max_tokens <= 模型上下文限制
- 被动检测（overflow detection）：当模型API因上下文超限而报错时，OpenClaw会识别特定的错误模式：
    - request_too_large
    - context length exceeded
    - input exceeds the maximum number of tokens
    - input token count exceeds the maximum number of input tokens
    - input is too long for the model
    - ollama error: context length exceeded

### 7. 上下文超限了怎么办？

当OpenClaw检测到上下文超限或已经超限时，会按照以下顺序采取行动，OpenClaw的上下文超限检测分布在LLM调用生命周期的三个关键节点：
检测阶段               |触发时机                   | 核心位置                                                |检测目的
调用前：主动检测        |每次向LLM发送请求之前       | tool-result-context-guard.ts的transformContext钩子      |预估上下大小，提前规避超限
调用后：被动响应        |LLM API返回错误之后         |run.ts的promptError处理分支                              |识别API返回的超限错误，触发恢复机制
错误链：深度检测        |处理任何异常时              |failover-error.ts的collectErrorChainMessages            |穿透错误包装，找到根本原因

#### 1 第一道防线：调用前主动预防：transformContext钩子（修剪与截断）
    在请求发送前，OpenClaw会进行一些减负操作，以主动避免超限。
    - 会话修剪（session pruning）：这是一种轻量级策略，在每次LLM调用前，从上下文中裁剪掉旧的工具结果（如执行结果、文件读取内容等），以减少上下文膨胀。它不会改下普通的对话文本。
    - 工具输出截断（tool result truncation）：大型工具输出会被自动截断。默认情况下，单个工具结果的字符数上限为 16000 字符。对于上下文窗口更大的模型（如200K+）,此上限会提升至64000字符。此配置通过agents.defaults.contextLimits.toolResultMaxChars调整。

    整个机制主要解决“工具循环（tool loop）中上下文悄然增长”的问题，在长工具调用循环中，每次工具执行结果都会追加到上下文，若不干预，可能在循环中间就超限了。
    核心代码：src/agent/pi-embedded-runner/tool-result-context-guard.ts

    //定义两个关键阈值
    const TOOL_RESULT_COMPACTION_TARGET = 0.75; //工具结果压缩目标：上下文窗口的 75%
    const PREEMPTIVE_OVERFLOW_RATIO = 0.9;  // 主动检测阈值：上下文窗口的 90%

    export function transformContext(context: Context): Context {
        // 1. 首先执行常规的工具结果压缩，目标就是占满窗口的 75%
        let compactionContext = compactToolResults(context,{
            targetRatio: TOOL_RESULT_COMPACTION_TARGET
        });

        // 2. 主动超限检测
        const estimationTokens = estimateContextTokens(compactedContext);
        const contextLimit = getContextWindowLimit();
        const currentRatio = estimatedTokens / contextLimit;

        // 3. 如果压缩后，上下文占比仍然占用超过 90%的主动检测阈值
        if (currentRatio >= PREEMPTIVE_OVERFLOW_RATIO){
            // 抛出特定错误，触发上层的溢出恢复流程
            return new Error("Preempptive context overflow:context still exceeds 90% after tool-result compaction");
        }

        return compactedContext;
    }
    这段代码的逻辑：
    - 先压缩：调用compactToolResults,尝试通过裁剪旧的工具输出来压缩上下文，目标是将上下文控制在窗口的 75%以内；
    - 再检测：压缩后，重新估算上下文大小；
    - 触发保护：如果压缩后上下文占比仍然超过 90%，说明单靠裁剪工具结果已无法有效控制大小。此时会抛出一个错误。
    - 上层梳理：这个错误会被run.ts捕获，并触发完整的LLM会话压缩（Compaction）流程。

#### 2. 第二道防线：核心策略（自动压缩Compaction）
    当主动预防不足以控制上下文大小时，自动压缩（auto-compaction）便会介入。这是OpenClaw解决上下文超限的核心机制。
    - 触发时机：当会话接近上下文限制时，或在模型返回上下文溢出错误后，OpenClaw会先压缩再试。
    - 工作原理：
        - 总结：将较旧的对话轮次（包括成对的工具调用和结果）压缩成一个精简的摘要（Summary）。
        - 保留：最近的消息保持完整；
        - 持久化：生成的摘要会保存在会话转录（session transcript）中。完整的对话历史仍保留在磁盘上，压缩只改变模型在下一轮能看到的内容。
    - 手动触发：用户也可以在聊天中输入 /compact命令来手动触发压缩。

    当预防措施失效，LLM API直接返回超限错误时，OpenClaw会通过匹配来识别。核心代码位于：src/agents/pi-embedded-helpers/errors.ts等工具函数中，OpenClaw会匹配以下工人的Provider错误模式：
    - request_too_large
    - context length exceeded
    - input exceeds the maximum number of tokens
    - input token count exceeds the maximum number of input tokens
    - input is too long for the model
    - ollama error: context length exceeded
    在run.ts的错误处理分支中，会调用类似 isLikelyContextOverflowError(error) 的工具函数进行判断段。一旦匹配，就会进入自动压缩和重试流程。此外，对于一些非标准错误，如HTTP 503等，若其按时服务过载，也可能触发相同的恢复流程。

#### 3.第三道防线：错误恢复与重试:collectErrorChainMessages
    如果上下文溢出错误仍然会发生，OpenClaw的外层恢复循环（runEmbeddedPiAgent）会介入处理：
    - 触发压缩并重试：当检测到上下文溢出错误后，OpenClaw会触发自动压缩，然后使用压缩后的上下重新尝试（retry）原始请求。
    - 错误分类与处理：根据错误类型进行处理
        - 可恢复错误：如上下文溢出、限流、超时等进行重试；
        - 认证错误：标记当前认证配置失效，尝试轮换到下一个可用的认证配置；
        - 致命错误：终止整个流程。

    在实际运行中，原始的超限错误可能被多层包装（例如，被网络库或传输层包装）。为了准确识别OpenClaw会遍历整个错误链。核心代码在 src/agents/failover-error.ts

    /*
    * 收集错误联众所有非空的消息
    * 采集深度优先遍历，安全处理循环引用
    */
    export function collectErrorChainMessages(err: unknown): string[] {
        const messages: string[];
        const visited = new Set<any>();
        let current = err;

        while (current && !visited.has(current)){
            visited.add(current);

            //如果当前错误对象由message属性且非空，则收集
            const msg = getErrorMessage(current);
            if (msg){
                messages.push(msg);
            }

            //继续遍历error 或cause属性，深入下一层
            current = getErrorCause(current) ?? getErrorProperty(current,'error');
        }

        return messages;
    }

    这段代码的价值在于：它能穿透多层包装。例如，最外层错误是 "request failed",但其内部是cause "context length exceeded"。collectErrorChainMessages会收集到这两个消息，从而让上层的判断逻辑能准确识别出根本原因是上下文超限。

## 2 整体流程
[ LLM 调用前 ]
      |
      v
[ transformContext 钩子 ]
      |
      +--> 1. 压缩工具结果 (目标: 75%)
      |
      +--> 2. 估算压缩后大小
      |       |
      |       +--> 若 > 90%: 抛出 "Preemptive context overflow" 错误 ──┐
      |       |                                                       |
      |       +--> 若 <= 90%: 正常发送请求 ──────────────────────┐    |
      |                                                         |    |
[ LLM 调用后 ]                                                   |    |
      |                                                         |    |
      v                                                         |    |
[ 处理 API 响应 ]                                                |    |
      |                                                         |    |
      +--> 成功: 返回结果 ◄─────────────────────────────────────┘    |
      |                                                               |
      +--> 失败 (错误):                                              |
              |                                                       |
              v                                                       |
      [ 错误链深度检测 ]                                             |
      (collectErrorChainMessages)                                    |
              |                                                       |
              +--> 匹配超限错误模式? ──── 是 ────► [ 触发自动压缩 ] ◄─┘
              |                                   (compactEmbeddedPiSessionDirect)
              +--> 否
                      |
                      v
              [ 其他错误处理流程 ]