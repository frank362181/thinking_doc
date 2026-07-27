### OpenClaw的CLI的入口
当在command line窗口输入openclaw 命令时，程序会动态导入./cli/run-main.js，然后执行runCli(argv)。源码中可以看到这样的逻辑:runMainOrRootHelp会先尝试root help fast path，再尝试预计算command help fast path,最后导入run-main.js并调用runCli(argv)。
这说明 OpenClaw 的CLI 是分层的：
-   entry.js 轻量入口、环境准备、快速路径
-   run-main.ts 进入完整的CLI流程
-   program 模块：构建命令系统
-   commands 模块：承载具体业务命令

### 构建 commander program
OpenClaw使用commander构建CLI命令系统。在src/cli/program/build-program.ts中，可以看到程序创建了一个新的command对象，然后依次配置帮助信息、注册pre-action hook、注册程序命令，最后返回构建好的program。
简化来看，buildProgram的作用是：
创建command实例 -> 开启positional options -> 设置exitOverride -> 创建program context -> 配置help输出 -> 注册pre-action hooks -> 注册所有命令 -> 返回programd
其中，exitOverride比较重要，它的作用是拦截Commander默认的退出行为，让程序在遇到未知命令或参数错误时，可以保留正确的退出码，并有OpenClaw自己控制错误输出流程。


###  命令注册机制
OpenClaw的命令不是全部硬编码在一个巨大的文件里面的，而是通过"描述符 + 注册器"的方式组织：在src/cli/program目录下，可以看到大量的与命令注册相关的文件，例如 build-program.ts、command_registry.ts、cor-command-descriptors.ts、register.subclis.ts、subcli-descriptors.ts等。这个

src/cli/program目录就说明了OpenClaw把CLI命令系统做成了一个独立的子模块。
其中core-command-descriptors.ts为核心命令描述信息。例如源码中可以看到crestodian、setup、onboard等命令，他们都是name、description、hasSubCommands等字段。

命令的描述如下：
 {
    name: "onboard",
    description: "Interactive onboarding for gateway, workspace, and skills",
    hasSubcommands: false,
 }
然后注册逻辑再根据这根据这些描述信息，把命令挂到Commander program上。这种设计的好处有：
-   命令元信息集中维护
-   命令注册逻辑统一处理
-   业务实现可以拆解到独立文件
-   帮助信息可以自动生成
-   插件或扩展命令更容易接入

### 子CLI的懒加载注册
register.subclis.ts展示了OpenClaw对子命令注册的进一步封装，源码中可以看到，它会获取子CLI描述符，然后通过buildCommandGroupEntries构建命令组，并根据当前argv判断是否eager注册、是否只注册主命令。
这里的关键信息是 ： 并不是所有命令必须一开始全部加载，例如用户执行：openclaw setup
那么程序只需要加载openclaw setup相关逻辑，不一定要把agent、channels、gateway、backup等所有命令实现都完整加载进来。这种设计适合大型CLI项目，因为可以降低启动成本，也能让命令模块之间的耦合度更低。

### CLI架构
CLI的主要执行流程：
-   entry.ts负责启动
-   run-main.ts负责进入主流程
-   build-program.ts负责构建主要命令程序
-   command descriptors负责描述命令
-   register 模块负责挂载命令
-   commands负责具体业务

