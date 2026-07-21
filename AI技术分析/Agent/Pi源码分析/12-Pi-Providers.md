
## providers
Pi支持两类Provider:基于订阅的（通过OAuth）和API Key（通过环境变量或auth文件）。对于每个Provider，Pi知道所有可用的模型，模型的列表随每次发布Pi更新。

## 1. 订阅
在交互模式下运行 /login 并选择Provider
- ChatGPT plus/Pro(Codex)
- Claude Pro/Max
- GitHub Copilot
使用 /logout 清除已经存储的凭证。token存储在 ~/.pi/agent/auth.json中，过期自动刷新。

## 2. API Keys
环境变量或 Auth文件

使用 /login在交互模式下选择Provider将 API Key存储到 auth.json中，或通过环境变量设置凭证：

    export AUTHROPIC_API_KE = sh-ant-...
    pi

Auth.json文件内容如下，文件以0x00权限创建（仅用户可读写）。Auth文件凭证优先于环境变量。

    {
        "anthropic":{"type":"api_key","key":"sk-ant...."},
        "ant-ling":{"type":"api_key","key":"...."},
    }

Auth.json的配置信息中,key可以使用环境变量来替换，如 "$ENV_VAR" 或 "${ENV_VAR}"。

## 3. 自定义 Provider
通过model.json：添加Ollama、LM Studio、vLLM或任何支持兼容API（OpenAI Completions,OpenAI Responses、Anthropic Messages、
Google Generative AI）的provider。如model.json描述所示：

### 1. model.json最小示例

    {
        "providers": {
            "ollama": {
                "baseUrl": "http://localhost:11434/v1",
                "api":"openai-completios",
                "apiKey":"ollama",
                "models":[{"id":"llama3.1:8b"},{"id":"qwen2.5-coder:7b"}]
            }
        }
    }
apiKey的值仅仅只是一个占位符，因为ollama会忽略它。Pi仍然会将模型视为需要认证后才会出现在 /model中，因此吴密钥的本地服务器用保留要给虚拟值、
通过 /login为该provider保存密钥，或在选择模型时传入 --api-key。

可以在Provider级设置 compat以用用于所有模型，也可以在模型级别设置以覆盖特定模型。这通常适用于Ollama、vLLM、SGLang等OpenAI兼容服务器。
完整示例：
    
    {
        "providers": {
            "ollama": {
                "baseUrl": "http://localhost:11434/v1",
                "api":"openai-completions",
                "apiKey":"ollama",
                "models":[
                    {
                        "id":"llama3.1:8b",
                        "name":"llama 3.1 8B(Local)",
                        "reasoning": false,
                        "input":["text"],
                        "contextWindow": 128000,
                        "maxTokens":32000,
                        "cost" {"input": 0,"output": 0,"cacheRead":0,"cacheWrite":0}
                    }
                ]
            }
        }
    }
该文件会在每次打开 /model 时重新加载。在会话期间编辑，无需重启。

## 4. 注册自定义的Providers
### 1. 覆盖现有的provider

最简单的用例是将现有的Provider通过代理重定向:

    // 所有的 Anthropic请求通过你的代理

    pi.registerProvider(
        baseUrl: 'https://proxy.example.com',
    );
    
    // 为OpenAI请求添加自定义请求头
    
    pi.registerProvider({
        headers: {
            'X-Corp-Auth','$CORP_AUTH_TOKEN', //环境变量引用或字面值
        },
    });

当只提供baseUrl和 或 /headers(没有models)时，该Provider的所有现有模型保留并使用新端点。

### 2. 注册新的Provider
要添加全新的Provider，指定models和所需配置。如果模型列表来自远端端点，使用异步扩展工厂：
    
    import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
    export default async function (pi: ExtensionAPI) {
        const response = await fetch('http://localhost:1234/v1/models');
        const payload = (await response.json()) as {
            data: Array<{
            id: string;
            name?: string;
            context_window?: number;
            max_tokens?: number;
            }>;
        };
        
        pi.registerProvider('local-openai', {
            baseUrl: 'http://localhost:1234/v1',
            apiKey: '$LOCAL_OPENAI_API_KEY',
            api: 'openai-completions',
            models: payload.data.map((model) => ({
                id: model.id,
                name: model.name ?? model.id,
                reasoning: false,
                input: ['text'],
                cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
                contextWindow: model.context_window ?? 128000,
                maxTokens: model.max_tokens ?? 4096,
            })),
        });
    }

这会在启动完成前注册收取到的模型：

    pi.registerProvider('my-llm', {
        baseUrl: 'https://api.my-llm.com/v1',
        apiKey: '$MY_LLM_API_KEY', // 环境变量引用
        api: 'openai-completions', // 使用的流式 API
        models: [{
            id: 'my-llm-large',
            name: 'My LLM Large',
            reasoning: true, // 支持扩展思考
            input: ['text', 'image'],
            cost: {
            input: 3.0, // $/百万 token
            output: 15.0,
            cacheRead: 0.3,
            cacheWrite: 3.75,
            },
            contextWindow: 200000,
            maxTokens: 16384,
        },],
    });
当提供models时，它会替换该Provider的所有现有模型。apiKey和自定义请求头值使用于models.json相同的配置语法：开头的
!command将整个值作为命令执行，$ENV_VAR 和 ${ENV_VAR}插值环境变量， $$产生字面值 $，$!产生直字面值!。

### 3. 认证请求头
如果你的Provider需要Authorization:Bearer <key> ，但不使用标准API，设置 authHeader: true:
    
    pi.registerProvider(
        baseUrl: "https://api.example.com",
        apiKey:"$MY_API_KEY",
        authHeader: true, // 添加 authorization: Bearer请求头
        api: "openai-completions",
        models: [...]
    );
密钥每次请求时解析，显式的请求Authorization请求头优先于生成的值。

### 4. OAuth支持

添加对OAuth的支持，添加OAuth/SSO认证，集成 /login：

    import type {} from "@earendil-works/pi-ai";
    pi.registerProvider("corporate-ai", {
        baseUrl: "https://ai.corp.com/v1",
        api:"openai-responses",
        models: [...],
        oauth: {
            name: "Corporate AI(SSO)",

            async login(callbacks: OAuthLoginCallbacks): Promise<OAuthCredentials> {
                const method = await callbacks.onSelect({
                    message: "选择登录方式：",
                    options: [
                        {id:"browser",label:"浏览器OAuth"},
                        {id: "device", label: "设备码"}
                    ]
                });
                if (!method) throw new Error("登录已经取消");

                let code = string;
                if (method === "device") {
                    callbackx.onDeviceCode({
                        userCode: "ABCD-1234",
                        verificationUrl:"https://sso.corp.com/device",
                        intervalSecond: 5,
                        expireInSecond: 900
                    });
                    code = await pollDeviceCodeUnitilComplete();
                }else{
                    callbacks.onAuth({url:"https://sso.corp.com/authrize?..."});
                    code = await callbacks.onPrompt({message:"输入 SSO码："});
                }

                // 令牌（你的实现）
                const tokens = await exchangeCodeForTokens(code);

                return {
                    refresh: tokens.refreshToken,
                    access: tokens.accessToken,
                    expires: Date.now() + tokens.expiresIn * 1000
                };
            },

            async refreshToken():Promise<OAuthCredential> {
                const tokens = await refreshAccessToken(credentials.refresh);
                return {
                    refresh: tokens.refreshToken ?? credentials.refresh,
                    access: tokens.accessToken,
                    expires: Date.now() + tokens.expiresIn * 1000
                };
            },

            getApiKey(credential:OAuthCredentials): string {
                return credential.access;
            }
        }
    });

注册后，用户可以通过 /login corporate-ai进行认证。以下是自定义的进行认证的函数：
callbacks对象为Provider自有流程提供UI中立的交互模式：
    
    interface OAuthLoginCallbcks {
        //在浏览器中打开URL（用于OAuth重定向）
        onAuth(params: {url: string}):void;

        //显示设备码（用于设备码授权流程）
        onDeviceCode({
            userCode: string;
            verificationUrl: string;
            intervalSeconds?: number;
            expiresInSeconds?:number;
        }):void;

        // 显示进度
        onProgress?(message: string):void;

        //提示用户输入
        onPrompt(params: {message: string}): Promise<string>;

        // 显示交互选择器
        onSelect(params:{message: string, options:{id:string,label:string}[]}): Promise<string | undefined>;
    }

凭证持久化存储在 ~/.pi/agent/auth.json中

    interface OAuthCredentials{
        refresh: string; //刷新令牌
        access: string; // 访问令牌，由getApiKey()返回
        expires: number; //过期时间
    }
        