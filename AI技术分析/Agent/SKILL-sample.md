---
name: github-issue-creator //技能的唯一标识，用于在openclaw.json的允许列表（allowlist）中引用。被loadSkills函数读取，作为技能的主键；若缺失则使用文件夹名称
description: | //技能的描述，会出现在 <available_skills>列表中，供模型选择，被loadSkills提取，注入到system prompt中，帮助模型决定何时调用该技能
  Create GitHub issues with proper labels, assignees, and project boards.
  Use this skill when the user asks to create, file, or report an issue on GitHub.
metadata:
  openclaw:
    emoji: 🐙 //可选的表情符号，被resolveOpenClawMetadata提取，作为辅助标识
    os: ["darwin", "linux"] //array 支持的 OS 列表，被resolveOpenClawMetadata读取
    always: false // 表示技能是否可用，若为true，则无论上下文如何，表示该技能一直可用，被resolveOpenClawMetadata提取
    primaryEnv: GITHUB_TOKEN //主要的环境变量名，被resolveOpenClawMetadata读取
    requires:
      bins: ["gh"] //所需的外部命令行工具列表，被resolveOpenClawMetadata读取
      env: ["GITHUB_TOKEN"] //所需的环境变量列表，被resolveOpenClawMetadata读取
      config: ["~/.config/gh/hosts.yml"] //所需的配置文件路径列表，被resolveOpenClawMetadata读取
invocation:
  mode: tool //调用模式，"tool"表示作为工具调用，"command"则表示为命令行调用，"always"表示自动注入等，被resolveSkillInvocationPolicy读取
  allowed: true //表示是否允许被调用，由resolveSkillInvocationPolicy读取
---

//以上的frontmatter的YAML元数据在Agent启动时（openclaw agent -<agentid> -message "message"命令运行时）被loadSkillEntries读取并缓存，其中'requires'相关的过滤逻辑'loadSkillEntries'中通过'resolveOpenClawMetadata提取，然后可能在后续的过滤阶段（如filterSkillsByRequirements'）中执行实际的检查，不满足条件的技能不会被注入到System Prompt中。

# GitHub Issue Creator Skill

## Overview
This skill provides a reliable workflow for creating GitHub issues using the official GitHub CLI (`gh`). It handles authentication, label validation, assignee mapping, and project board association.

## Prerequisites
- GitHub CLI (`gh`) installed and authenticated.
- `GITHUB_TOKEN` environment variable set with `repo` scope.

## Steps

1. **Validate the repository context**
   - Ensure the current working directory is a Git repository with a remote `origin` pointing to GitHub.
   - If not, ask the user for the repository full name (e.g., `owner/repo`).

2. **Gather issue details**
   - Title (required) – from user input or derive from conversation.
   - Description (required) – can include markdown, code blocks, and checklist items.
   - Labels (optional) – validate against repository labels; offer suggestions if invalid.
   - Assignees (optional) – GitHub usernames; validate existence.
   - Milestone (optional) – number or title; validate existence.
   - Project board (optional) – project ID or board name; add to project column if specified.

3. **Create the issue using `gh`**
   ```bash
   gh issue create --repo <repo> --title "<title>" --body "<description>" --label <label1> --assignee <assignee>

   /*
   * SKILL.md的第二部分是markdown的正文
   *
   * Overview 
   *    简要介绍技能的用途和适用场景。帮助模型快速理解技能的黑奴目标
   *
   * Prerequisites
   *    明确运行该技能所需的前置条件（工具、环境变量、权限等），避免模型在执行因缺少依赖而失败，同时也为用户提供准备指导。
   *
   * Steps
   *    逐步的操作流程，通常为有序号的编号列表，指导模型按步骤执行，确保可复现性和准确性。
   *
   * Example Usage
   *    提供一个具体的使用案例，包括用户输入和Agent应执行的操作与响应。给模型一个清晰的参考，提升执行准确性，尤其是对于复杂的多步骤任务。
   *
   * Notes
   *    补充说明、注意事项、边界情况等。帮助模型避开常见陷阱，处理边缘情况。
   */

   /*
   *
   * OpenClaw 如何处理该 SKILL.md
   *
   * 1. 加载阶段
   *    - 'loadSkillEntries':扫描目录，发现此文件
   *    - 'parseFrontmatter':分理处YAML头部和markdown正文
   *    - 'parseYamlFrontmatter':解析YAML为对象
   *    - 'resolveOpenClawMetadata':提取'matadata.openclaw字段
   *    - 'resolveSkillInvocationPolicy'：提取'invocation'字段
   *    - 基于requires字段检查环境（如'gh'是否可执行，'GITHUB_TOKEN'是否设置），若满足则保留该技能
   *
   * 2. 注入阶段
   *    技能的名称（'name'）和描述（'description'）会被放入'<available_skills>'XML块中，并插入system prompt。例如：
   *    '''xml
   *    <available_skills>
   *        <skill>
   *            <name>github-issue-creator</name>
   *            <description>Create GitHub issues with proper labels, assignees, and project boards. Use this skill when the user asks to create, file, or report an issue on GitHub.</description>
   *            <location>/path/to/SKILL.md</location>
   *         </skill>
   *    </available_skills>
   *
   *
   * 3.执行阶段
   *   用户提问：帮我创建一个github issue时，模型根据<available_skills>中描述，判断该技能匹配
   *   模型调用read工具，传入<location>路径，读取完整的markdown正文
   *   模型更具正文中的步骤执行（如调用gh命令）
   *   执行结果返回给用户
   */