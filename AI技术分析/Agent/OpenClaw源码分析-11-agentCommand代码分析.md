## 1. 推理和工具调用循环
在 buildAgentSystemPrompt构建完系统提示词（System Prompt）后，OpenClaw会通过一个双层循环架构来调用大模型，并将System Prompt与用户消息一并提交。这个流程清晰地分为三个层次：入口调度层、执行尝试层和核心循环层。

整个流程的代码调用路径如下：
runEmbeddedPiAgent（外层恢复循环） -> runEmbeddedAttempt（单次执行尝试）-> activeSession.prompt（Pi核心循环）-> streamFn（模型API调用）

buildAgentSystemPrompt之后到最终API调用的完整链路：

  runEmbeddedPiAgent（外层恢复循环）{
  |
  |-> 解析模型 / 账号 / 上下文窗口
  |-> while (true) {
          runEmbeddedAttemp（单次执行尝试）
          设置工作区 / 沙箱
          组装工具集（createOpenClawCodingTools）
          创建 Pi 会话 （createAgentSession）
          |-> 注入system prompt

          session.prompt(userMessage) <- 提交用户消息
          |
          | -> Pi Agent Core (ReAct)循环
              while(true){
                  streamFn (可替换的LLM调用函数)
                  |-> HTTP 请求 -> LLM API
                      |-> system prompt
                      |-> messages (含用户消息)
                  
                  若返回Tool Call -> 执行工具 -> 继续循环
                  若返回最终恢复 -> 捷顺循环
              }
              返回结果给runEmbeddedAttempt
      }
      判断结果：成功->返回 / 可恢复错误 -> continue / 致命错误 -> throw
  }

### 1. 第一层：入口调度层（runEmbededPiAgent）
runEmbeddedPiAgent是Agent执行的总入口，它负责管理整个执行的生命周期。
-   核心职责：不直接处理模型推理，而是作为一个恢复循环（recovery loop）,为一次用户请求管理 1 到 N次执行尝试；
-   主要任务：
    -   为这次请求选择合适的模型、provider 和 认证账号
    -   管理充实逻辑，处理如令牌过期、provider过载、上下文溢出等可恢复错误；
    -   在失败时，绝对顶进行账号轮换、模型降级还是发起新的执行尝试。

其核心代码是一个while (true)循环，内部调用 runEmbeddedAttempt，代码在src/agents/pi-embedded-runner/run.ts

// 文件位置: src/agents/pi-embedded-runner/run.ts[reference:2][reference:3]

  export async function runEmbeddedPiAgent(
    params: RunEmbeddedPiAgentParams
  ): Promise<EmbeddedPiRunResult> {
    // ----- 1. 队列与锁：确保会话安全 -----
    // 通过会话级队列（session lane）和全局队列（global lane）进行排队[reference:4]
    // 获取会话文件的独占写锁，防止并发冲突[reference:5][reference:6]
    await enqueueInLanes({
      sessionLane: resolveSessionLane(params.sessionKey ?? params.sessionId),
      globalLane: resolveGlobalLane(params.lane),
    });
    await acquireSessionWriteLock(params.sessionKey);

    // ----- 2. 插件钩子与模型解析 -----
    // 触发 before_model_resolve 钩子，插件可在此覆盖 provider/model[reference:7]
    const hookOverrides = await getGlobalHookRunner().run('before_model_resolve', params);
    const resolvedModel = await resolveModel({
      provider: hookOverrides?.provider ?? params.provider,
      model: hookOverrides?.model ?? params.model,
      config: params.config,
    });

    // 解析认证配置文件（Auth Profile）的候选列表[reference:8][reference:9]
    const profileCandidates = await resolveAuthProfileOrder({
      provider: resolvedModel.provider,
      authProfileId: params.authProfileId,
      config: params.config,
    });

    // ----- 3. 外层重试循环（Auth Profile 轮换） -----
    // 最大迭代次数 = 24 + 候选数 × 8，限制在 [32, 160][reference:10]
    const maxRetries = resolveMaxRunRetryIterations(profileCandidates.length);
    
    for (let profileIndex = 0; profileIndex < profileCandidates.length && profileIndex < maxRetries; profileIndex++) {
      const currentProfile = profileCandidates[profileIndex];
      
      // 检查当前 Profile 是否在冷却期（Cooldown）[reference:11]
      if (isProfileInCooldown(currentProfile)) {
        continue; // 跳过冷却中的 Profile
      }

      // 触发 before_agent_start 钩子[reference:12]
      await getGlobalHookRunner().run('before_agent_start', { ...params, profile: currentProfile });

      try {
        // ----- 4. 内层重试循环（可恢复错误重试） -----
        // 针对上下文溢出（Context Overflow）等可恢复错误进行重试[reference:13]
        while (true) {
          try {
            // ----- 5. 调用 runEmbeddedAttempt 执行单次尝试 -----
            // 所有工具组装、会话创建、历史加载、模型调用都在这里完成[reference:14]
            const result = await runEmbeddedAttempt({
              ...params,
              profile: currentProfile,
              resolvedModel,
              // 注意：clientTools 从 params 透传[reference:15]
              clientTools: params.clientTools, 
            });

            // 成功：标记 Profile 可用，返回结果[reference:17]
            await markAuthProfileGood(currentProfile);
            return result;

          } catch (error) {
            // ----- 6. 错误分类与恢复 -----
            const failoverReason = classifyError(error); // 例如: context_overflow, rate_limit, auth[reference:18]

            // 如果是上下文溢出，触发会话压缩（Compaction）后重试[reference:19]
            if (failoverReason === 'context_overflow') {
              await compactSession(params.sessionKey);
              continue; // 压缩后重新尝试
            }

            // 如果是认证错误，标记失败并进入冷却[reference:20]
            if (failoverReason === 'auth' || failoverReason === 'auth_permanent') {
              await markAuthProfileFailure(currentProfile);
              break; // 跳出内层循环，尝试下一个 Profile
            }

            // 如果是可恢复的临时错误（如限流、超时），直接重试
            if (isRetryable(failoverReason)) {
              continue;
            }

            // 其他错误：抛出，终止整个流程
            throw error;
          }
        }
      } finally {
        // 清理资源：如 MCP 运行时等[reference:21]
        await cleanupRunResources(params.sessionKey);
      }
    }

    // 所有 Profile 尝试失败
    throw new NoAvailableAuthProfileError();
  }

### 2. 第二层：执行尝试（runEmbeddedAttempt）
runEmbeddedAttempt是“一次完整的执行尝试”。runEmbeddedPiAgent的每一次循环迭代，都会调用一次该函数。
-   核心职责：负责为单次尝试准备所有的运行环境，并启动Pi Agent核心
-   主要任务：
    -   设置工作区与沙箱：为本次执行准备文件与隔离环境；
    -   组装工具集：通过createOpenClawCodingTools等函数，将可用的工具（如exce,read,write等）组装好；
    -   构建OpenClaw会话：将所有准备好的组件（模型配置、工具、系统提示词等）打包，创建一个Pi Agen会话；
    -   启动Pi核心循环：调用会话对象的 prompt()方法，将控制权交给Pi Agent核心
    -   处理流式事件：订阅并处理来自Pi核心的流式事件（如模型输出的增量文本、工具调用请求等），并将其桥接到OpenClaw的事件流中

  // src/agents/pi-embedded-runner/run/attempts.ts
  // src/agents/pi-embedded-runner/run/attempts.ts

  import { resolveSandboxContext } from '../sandbox/resolver';
  import { createOpenClawCodingTools } from '../../tools/factory';
  import { createAgentSession } from '../pi/session';
  import { emitOpenClawEvent } from '../../events/emitter';
  import type { RunEmbeddedAttemptParams, AttemptResult } from './types';

  /**
  * 执行单次 Agent 尝试（含沙箱准备、工具装配、Pi 会话运行）
  */
  export async function runEmbeddedAttempt(
    params: RunEmbeddedAttemptParams
  ): Promise<AttemptResult> {
    // ----- 1. 解析沙箱上下文（最重要的一步） -----
    // 根据 Agent 配置、会话标识、工作区路径，裁决是否启用沙箱，
    // 并返回具体的沙箱参数（容器镜像、挂载方式、资源限制等）
    const sandbox = await resolveSandboxContext({
      config: params.agentConfig,          // Agent 的完整配置
      sessionKey: params.sessionKey,       // 会话唯一标识（用于容器复用）
      workspaceDir: params.workspaceDir,   // 宿主机工作区根目录
    });

    // ----- 2. 确定最终有效的工作区目录 -----
    // 如果沙箱启用，工作区指向容器内的路径（由沙箱桥接层映射）；
    // 否则直接使用宿主机路径
    const effectiveWorkspace = sandbox.enabled
      ? sandbox.containerWorkspacePath   // 例如 "/workspace"
      : params.workspaceDir;             // 例如 "/home/user/.openclaw/workspace"

    // ----- 3. 准备沙箱文件系统桥接（仅当启用沙箱） -----
    // 该桥接负责在宿主机路径和容器路径之间做翻译，使工具调用的路径始终有效
    const fsBridge = sandbox.enabled
      ? await createSandboxFsBridge({
          hostRoot: params.workspaceDir,
          containerRoot: sandbox.containerWorkspacePath,
          containerId: sandbox.containerId,
        })
      : null;

    // ----- 4. 组装工具集（注入沙箱感知能力） -----
    // createOpenClawCodingTools 会根据 sandbox 和 fsBridge 决定创建何种工具：
    // - 若沙箱启用，则生成 'sandboxedRead', 'sandboxedWrite', 'sandboxedExec' 等
    // - 若沙箱关闭，则生成直接操作宿主机的 'fsRead', 'fsWrite', 'exec' 等
    const tools = createOpenClawCodingTools({
      workspace: effectiveWorkspace,
      sandbox,                // 传入沙箱上下文，工具工厂据此分支
      fsBridge,               // 传入桥接，用于路径转换
      sessionKey: params.sessionKey,
      // 其他配置（如超时、文件大小限制等）
      maxFileSize: params.maxFileSize ?? 10 * 1024 * 1024,
      timeout: params.toolTimeout ?? 30000,
    });

    // ----- 5. 创建 Pi Agent 会话（模型交互核心） -----
    // 会话对象负责与 LLM 通信，并驱动工具调用循环
    const session = await createAgentSession({
      model: params.model,
      tools: tools,
      systemPrompt: params.systemPrompt,
      // 将沙箱上下文注入到系统提示中（例如告诉 Agent 当前工作区路径）
      additionalContext: {
        workspace: effectiveWorkspace,
        sandboxed: sandbox.enabled,
      },
      // 其他会话参数（温度、maxTokens 等）
      temperature: params.temperature ?? 0.7,
      maxTokens: params.maxTokens ?? 4096,
    });

    // ----- 6. 订阅 Pi 核心事件，桥接到 OpenClaw 事件流 -----
    // Pi 会发出文本增量、工具调用、生命周期等事件，统一转换为 OpenClaw 的标准事件
    const subscription = session.subscribe((piEvent) => {
      const openClawEvent = translatePiEvent(piEvent, { sandbox, fsBridge });
      emitOpenClawEvent(openClawEvent);
    });

    // ----- 7. 执行用户提示（核心调用） -----
    try {
      // 这是真正的模型调用入口，Pi 内部会循环调用工具直到完成任务
      const result = await session.prompt(params.userMessage, {
        // 可传入额外的信号或上下文
        signal: params.abortSignal,
        // 如果沙箱启用，可以设置执行超时（与容器生命周期联动）
        timeout: sandbox.enabled ? sandbox.executionTimeout : undefined,
      });

      // ----- 8. 返回成功结果 -----
      return {
        status: 'success',
        payload: result,
        metadata: {
          sandboxUsed: sandbox.enabled,
          containerId: sandbox.containerId,
          workspace: effectiveWorkspace,
        },
      };
    } catch (error) {
      // ----- 9. 错误处理与恢复判断 -----
      // 根据错误类型决定是否可重试（如网络超时、容器崩溃等）
      const isRecoverable = isRetryableError(error, sandbox);
      return {
        status: 'error',
        error,
        recoverable: isRecoverable,
        // 附带沙箱状态，便于上层决策
        sandboxState: sandbox.enabled ? 'active' : 'none',
      };
    } finally {
      // ----- 10. 清理资源（取消订阅、关闭桥接） -----
      subscription.unsubscribe();
      if (fsBridge) {
        await fsBridge.close(); // 释放路径映射缓存等
      }
      // 注意：容器不会在此销毁，因为其生命周期由 scope 策略管理（session/agent/shared）
      // 如果 scope === 'session'，则会在外层（runEmbeddedPiAgent）的 finally 中销毁
    }
  }

  /**
  * 辅助函数：将 Pi 事件转为 OpenClaw 事件
  */
  function translatePiEvent(piEvent: any, context: any): any {
    // ... 实现略
  }

  /**
  * 辅助函数：判断错误是否可重试
  */
  function isRetryableError(error: any, sandbox: any): boolean {
    // ... 实现略
  }

### 3. 第三层：核心循环与模型调用 （Pi Agent Core）
当runEmbeddedAttempt调用session.prompt(userMessage)后，控制权交给了Pi Agent Core。这是真正驱动Agent思考与行动的核心引擎。
-   核心职责：管理Agent的ReAct（Reasoning + Acting）循环；
-   工作流程：session.prompt()被调用后，Pi内部会启动一个自动循环；
    -   构造请求：将system prompt、对话历史（包含用户消息）和工具定义，组合成模型API所需的请求体；
    -   调用模型：通过streamFn函数像LLM API发送请求；
    -   处理响应：
        -   a.若模型返回最终回复，循环结束，返回结果
        -   b.若模型返回工具调用（Tool Call）请求，Pi会执行该工具，将结果作为新消息追加到对话历史中，然后回到步骤1，开始新一轮循环。
-   streamFn的作用：Pi的巧妙之处在于，其核心的LLM调用函数streamFn是可替换的（【StreamFn是可替换的】）。OpenClaw利用这一点，将默认的HTTP调用替换或包装为带有日志、追踪、超市控制等增强功能版本。

  // Pi Agent Core的内部逻辑
  class AgentSession {
      async prompt(userMessage: string) {
          // 1. 将用户消息加入历史
          this.messages.push({role:'user',content:userMessage});

          // 2. ReAct循环
          while (true) {
              // 3. 调用LLM（通过可替换的streamFn）
              const response = await this.streamFn({
                  system: this.systemPrompt, // system prompt在这里提交
                  messages: this.messages, // 包含用户消息的完整历史
                  tools: this.toolDefinitions,
              });
          }

          // 4. 处理响应
          if(response.hasToolCalls()){
              //执行工具调用
              const toolResults = await this.executeTools(response.toolCalls);

              //将工具结果追加到历史，继续循环
              this.messages.push({role:'assistant',tool_calls:response.toolCalls });
              this.messages.push({role: 'tool',content:toolResults });
          }else{
              // 模型给出最终回复，结束循环
              return response.content;
          }
      }
  }

上诉类中AgentSession中的streamFn是在runEmbeddedAttemp函数接管AgentSession的创建过程，此时可以将streamFn替换为自己的实现，如：
session.agent.streamFn = createOllamaStremFn(baseUrl);
或
session.agent.streamFn = createOpenAIWebSocketStreamFn(...);

或
1. 记录日志的包装器
sesion.agent.streamFn = logger.wrapStreamFn(session.agent.streamFn);

2. 缓存与追踪的包装
session.agent.streamFn = cacheTrace.wrapStreamFn(session.agent.streamFn);
3.注入额外的参数包装
session.agent.streamFn = wrapNumCtx(session.agent.streamFn,numCtx);
