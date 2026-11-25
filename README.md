# OllamaKit

**OllamaKit** is a set of Lazarus / Free Pascal visual components for building desktop applications around [Ollama](https://ollama.com) — a local and remote large language model (LLM) server.

The package provides reusable building blocks that together deliver the following capabilities:

- an **asynchronous Ollama API client** with REST support and Server-Sent-Events (SSE) streaming,
- **model lifecycle management** (list, pull, start, stop, delete, copy, create, inspect, version),
- **streaming chat** with thinking and content callbacks,
- a **tool-calling LLM agent** with a complete agent loop, context management and history compaction,
- an **interactive terminal component** that hosts both shell commands and agent-driven sessions,
- **configuration, help and model-list helper** functions.

---

## Requirements

- **Lazarus** 3.x or newer (developed against Lazarus 4.8 with Free Pascal 3.2.2),
- **Free Pascal Compiler** (FPC) 3.2.x,
- Required Lazarus packages (all of them must be installed in the environment):

  | Package | Purpose |
  |---|---|
  | `LCLBase` | Base Lazarus class library support |
  | `IDEIntf` | Design-time integration (property editors, component registration) |
  | `helpers` | General helper utilities used by the units |
  | `toolkit` | HTTP / networking / string helper utilities; requires `laz_synapse` as its dependency |
  | `laz_synapse` | HTTP / web-socket transport required by the `toolkit` package |

---

## Main Functionality

### Ollama API client (`TOllamaManager`)

- Asynchronous refresh of installed / running model lists (`RefreshModels`).
- Background operations: pull, start, stop and refresh via a dedicated worker thread (`TOllamaBgThread`).
- Streaming pull progress with per-model percent updates (`OnPullProgress`).
- Chat and generate requests with SSE streaming (`ChatStream`, `ChatWithTools`) or plain JSON (`Chat`, `Generate`).
- Error handling with typed error kinds (`TOllamaErrorKind`) and retry logic for transient failures only.
- Server state queries: model context length, running model JSON, quick reachability check, version.
- Optional popup menu integration for model management actions.

### LLM agent (`TOllamaAgent`)

- Multi-step agent loop driven by the model, with a finish condition and maximum step limit.
- Streaming responses with content and thinking callbacks.
- Tool calling: built-in tools plus user-defined tools registered through a tool collection.
- Host-controlled routing (`OnRoute`) and execution hooks (`OnExecCommand`, `OnAskUser`, `OnToolResult`, ...).
- Context usage tracking and automatic history compaction.
- Multi-chat support with persistence (`NewChat`, `SwitchChat`, `SaveChatsToFile`, ...).

### Interactive terminal (`TTermManager`)

- Full-screen style interactive loop (`Run` / `Stop`).
- Input classification: empty, built-in, external shell command and agent command.
- Built-in commands (`cls`, `help`, `exit`, ...) and external shell execution with output capture.
- Agent session handling: prompt injection, streaming rendering, markdown processing, thinking blocks, tool call display, statistics and finish handling.

### Helpers (`AgentConfig`)

- Help text formatting, agent property get/set, features formatting, installed-models listing.

---

## Project Structure

```
ollamakit.lpk              Package project file
ollamakit.pas               Package unit stub (compilation / installation)
ollamakitregister.pas       Design-time component and property editor registration
ollamakit.lrs / ollamakit.rc  Resource scripts
src/
  ollamamanager.pas         TOllamaManager / TCustomOllamaManager (Ollama API client)
  ollamaagent.pas           TOllamaAgent / TCustomOllamaAgent (LLM agent)
  termmanager.pas           TTermManager / TCustomTermManager (interactive terminal)
  agentconfig.pas           Helper functions for commands, help and configuration
img/                        Icons
lib/<target>                Compiled output
```

---

## Component Interaction

The components form a single pipeline:

```
User input (terminal)
        |
        v
TTermManager.Run -> ReadLine -> ClassifyLine -> DoRoute -> dispatch
        |
        |-- tikBuiltin  -> HandleBuiltin / ExecuteCommand
        |-- tikCommand  -> ExecuteCommand (shell)
        `-- tikAgent   -> TCustomOllamaAgent.RunAsync
                          |
                          v
                   TOllamaAgentThread (worker)
                          |
                          v
                   TOllamaManager (ChatStream / ChatWithTools / Generate / Chat)
                          |
                          v
                   Ollama server (HTTP / SSE)
                          |
                          v
        Agent events -> TTermManager handlers -> console rendering
```

`TTermManager` owns an `TOllamaAgent` instance (property `Agent`). The agent owns / receives an `TOllamaManager` instance (property `OllamaManager`) which performs the actual HTTP calls. The terminal installs temporary agent event handlers (`OnChunk`, `OnThinking`, `OnToolCall`, `OnToolResult`, `OnFinish`, `OnExecCommand`, `OnAskUser`, `OnLog`, `OnContextUsage`) while a run is active and restores the previous handlers afterwards.

---

## Components

### 1. `TOllamaManager` (`src/ollamamanager.pas`)

Namespace / class names: `OllamaManager`, `TOllamaManager`, `TCustomOllamaManager`.

**Purpose:** asynchronous Ollama API client that hides the HTTP transport behind a background worker thread and provides the model lifecycle management, streaming chat and generate requests, typed error handling and server state queries.

- `RefreshModels` — triggers a background refresh of the model lists.
- `PullModel(const ModelName: string)` — starts an asynchronous model pull.
- `DeleteModel(const ModelName: string)` — deletes a model.
- `StartModel(const ModelName: string)` / `StopModel(const ModelName: string)` — start / stop a loaded model.
- `Connect` / `Disconnect` — enable / disable connection attempts.
- `Generate(const ModelName, Prompt: string): string` — non-streaming generate.
- `Chat(const ModelName, UserMessage: string): string` — non-streaming chat.
- `ChatStream(...)` (two overloads) — streaming chat with a single content callback, or with separate content and thinking callbacks; returns the final chunk or reports an error.
- `ChatWithTools(...)` (two overloads) — streaming or non-streaming chat with tools support; emits thinking and content.
- `ShowModel(const ModelName: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): string` — fetches model metadata JSON.
- `GetVersion(out Kind: TOllamaErrorKind; out ErrorMsg: string): string` — returns the server version.
- `CopyModel(const Source, Destination: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean` — copies a model.
- `CreateModel(const ModelName, ModelfileContent: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean` — creates a model from a Modelfile.
- `LoadModelSync(const ModelName: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean` / `UnloadModelSync(...)` — synchronous load / unload.
- `ResetUsage`, `GetLastUsageTotal`, `GetModelContextLength`, `GetRunningModelJson`, `CheckServerReachableQuick`, `BgFinished`, `UnregisterThread`.



**Events:**

- `OnModelsRefreshed(Sender, OldModels, NewModels: TStringList)`.
- `OnError(Sender, Kind: TOllamaErrorKind, ModelName, ErrorMsg: string)`.
- `OnPullProgress(Sender, ModelName: string, Percent: integer)`.
- `OnConnecting(Sender)` / `OnConnected(Sender)`.
- `OnModelStart(Sender, ModelName, External, Success, ErrorMsg)` / `OnModelStop(...)`.

**Types:** `TOllamaErrorKind` (`oekNone`, `oekUnknown`, `oekConnection`, `oekTimeout`, `oekHttpClient`, `oekHttpServer`, `oekJson`, `oekNotFound`, `oekCancelled`), `TOllamaMenuSection(s)`, `TOllamaBgOp` (`boPull`, `boStart`, `boStop`, `boRefresh`).

---

### 2. `TOllamaAgent` (`src/ollamaagent.pas`)

Namespace / class names: `OllamaAgent`, `TCustomOllamaAgent`, `TOllamaAgent`.

**Purpose:** LLM agent that runs a tool-calling loop on top of `TOllamaManager`. The agent builds the system prompt, manages conversation history and context usage, streams responses and executes tool calls until the finish condition, step limit, cancellation or an error occurs.

**Core loop (`TOllamaAgentThread`):**

1. Validates that an `OllamaManager` and a `ModelName` are assigned.
2. Checks tool support for the model (`ModelSupportsTools`).
3. Builds the system prompt via `BuildSystemPrompt` (platform, workspace root, AGENTS.md, enabled tools, environment facts).
4. Prepends history and the user message, with optional context prelude.
5. Streams the chat via `OllamaManager.ChatStream` / `ChatWithTools`.
6. Parses `tool_calls` and executes them (parallel batch for safe tools, sequential otherwise).
7. Repeats until `finish`, `MaxSteps`, cancellation or error.

**Features (`TAgentFeature`):**

- `afFileTools` — built-in file tools (read, write, edit, insert, replace, patch, delete, move, copy, list, glob, grep, info, read lines/preview, open, agents md),
- `afExecCommand` — shell execution via host hook,
- `afGit` — git tools executed through the host hook,
- `afInteractive` — ask-user tool,
- `afFinish` — finish tool,
- `afWebTools` — web fetch / search tools.

**Chats:** `TAgentChat` holds ID, name, working directory, history JSON, chat prompt, terminal history, shell log, terminal output, context counters, output marks and session state.

**Tools:** `TAgentTools` is a `TCollection` of `TAgentTool` (`Name`, `Description`, `ParametersJson`, `OnExecute`) plus `TAgentWebOptions` (`SearchUrl`, `UserAgent`, `RequestTimeout`, `MaxResponseBytes`, `StripHtml`, `BlockLocalhost`, `BlockPrivateIPs`, `AllowedHosts`).

**Properties:** `OllamaManager`, `ModelName`, `SystemPrompt`, `MaxSteps`, `RequestTimeout`, `EnabledTools`, `Streaming`, `RootPath`, `ToolPathAliases`, `Tools`, `WebOptions`, `KeepHistory`, `LoadAgentsMd`, `AgentsFileName`, `AllowAccessToSystem`, `BlockSensitiveFiles`, `Log`, `LogToolResult`, context properties (`ContextUsed`, `ContextTotal`, `ContextPercent`, `ContextUsedKb`, `ContextTotalKb`).

**Events:** `OnLog`, `OnContextUsage`, `OnRoute`, `OnChunk`, `OnThinking`, `OnToolCall`, `OnToolResult`, `OnExecCommand`, `OnAskUser`, `OnFinish`.

**Public API:** `RunAsync(const AText: string)`, `Run(const AText: string): string`, `Cancel`, `ClearHistory`, `RemoveLastExchange`, chat management (`NewChat`, `SwitchChat`, `MoveActiveChat`, `DeleteActiveChat`, `ClearChats`, `SaveChatsToFile`, `LoadChatsFromFile(s)`, `SaveChatToFile`, `LoadChatFromFile`), `BuildSystemPrompt`, `RefreshContextInfo`, `ResetUsage`.

---

### 3. `TTermManager` (`src/termmanager.pas`)

Namespace / class names: `TermManager`, `TCustomTermManager`, `TTermManager`.

**Purpose:** interactive terminal component that hosts shell commands and agent-driven sessions. It classifies user input, renders shell and agent output, handles built-in commands and drives agent runs through temporary event handlers.

**Functions / methods:**

- `Run` / `Stop` — start / stop the interactive loop.
- `ExecuteCommandCapture(const ACommand: string; out AExitCode: integer; ATimeoutMs: integer = -1): string` — shell execution with output capture.
- `WriteText(const AText: string; AIsStderr: boolean = False)` / `WriteLine(...)` — console output primitives.
- `FormatTermConfig` / `RestoreActiveChat` / `ReadLine` / `AddToHistory` / `IsExternalCommand` / `PumpOutput` / `HandleBuiltin` / `ExecuteCommand` / `ClassifyLine` / `DoRoute` / `DoOutput` / `DoAgentExecute` / `DoExit` / `CloseThinking` / `ProcessMarkdownChunk` / `ProcessMarkdownLine` / `RecordShellOperation` / `BuildShellContext` / `IsMetaCommand` / `IsChatControlCommand` / `HandleAgentExecCommand` / `HandleAgentAskUser`.

**Properties:** `Path`, `Prompt`, `StartupPrompt`, `Welcome`, `ThinkingLabel`, `ShowThinking`, `ShowAgentStats`, `AgentStatsFormat`, `ToolCallLabel`, `StripEmoji`, `StripSpecialChars`, `ColorOutput`, `Colors`, `DefaultModelLabel`, `WaitSlowHint`, `WaitServerDownHint`, `WaitCheckDelayMs`, `BuiltinCommands`, `HistoryMax`, `ShellExec`, `CommandTimeout`, `MaxCaptureBytes`, `AgentCommandTimeout`, `UsePrefixes`, `ShellHistory`, `SearchPath`, `LastExitCode`, `History`, `Running`, `OnRoute`, `OnOutput`, `OnAgentExecute`, `OnExit`, `Agent`.

**Agent event handlers:** `HandleAgentChunk`, `HandleAgentThinking`, `HandleAgentToolCall`, `HandleAgentToolResult`, `HandleAgentFinish`, `HandleAgentLog`, `HandleAgentContextUsage`, `HandleAgentExecCommand`, `HandleAgentAskUser`, `CloseThinking`.

**Input flow:** `Run` loop reads a line, classifies it (`tikEmpty`, `tikBuiltin`, `tikCommand`, `tikAgent`), routes it (`DoRoute`) and dispatches accordingly. Agent commands are forwarded to `TOllamaAgent.RunAsync` with temporary event-handler installation and cancellation support.

---

### 4. `AgentConfig` (`src/agentconfig.pas`)

**Purpose:** helper unit with pure functions for command handling, help formatting, agent property get/set, features formatting and installed-models listing.

**Functions:**

- `FormatShortHelp`, `FormatFullHelp(Agent: boolean; Term: boolean; Shortcuts: boolean)`, `FormatOllamaHelp`, `FormatAgentConfig(AAgent: TCustomOllamaAgent)`, `GetAgentProperty`, `SetAgentProperty`, `FormatModelsList(AAgent: TCustomOllamaAgent; out AError: string)`, plus the `TModelListCollector` event helper.

---

## Using the Components in the Designer

The components can be placed directly on a Lazarus form at design time.

1. Install the `ollamakit` package and its dependencies (`LCLBase`, `IDEIntf`, `helpers`, `toolkit`, `laz_synapse`).
2. Open the Tool Palette and drop the following components onto a form:
   - `TTermManager` (`TermManager`),
   - `TOllamaAgent` (`OllamaAgent`),
   - `TOllamaManager` (`OllamaManager`).
3. Wire the object hierarchy through properties:
   - `TTermManager.Agent` → an instance of `TOllamaAgent` (the terminal drives the agent),
   - `TOllamaAgent.OllamaManager` → an instance of `TOllamaManager` (the agent performs HTTP calls through it),
   - `TOllamaManager.BaseURL` → the Ollama server base URL (default `http://localhost:11434`).
4. Optionally configure:
   - `TTermManager.Path` — working directory for shell commands and agent file tools,
   - `TOllamaAgent.ModelName` — default model,
   - `TOllamaManager.KeepAlive` / `TOllamaManager.NumCtx`,
   - `TTermManager` timeouts and `MenuSections`.
5. Subscribe to events, for example:
   - `TOllamaManager.OnError`, `TOllamaManager.OnConnected`, `TOllamaManager.OnModelsRefreshed`, `TOllamaManager.OnPullProgress`, `TOllamaManager.OnModelStart`, `TOllamaManager.OnModelStop`,
   - `TOllamaAgent.OnChunk`, `TOllamaAgent.OnThinking`, `TOllamaAgent.OnToolCall`, `TOllamaAgent.OnToolResult`, `TOllamaAgent.OnFinish`, `TOllamaAgent.OnExecCommand`, `TOllamaAgent.OnAskUser`, `TOllamaAgent.OnLog`, `TOllamaAgent.OnContextUsage`, `TOllamaAgent.OnRoute`,
   - `TTermManager.OnOutput`, `TTermManager.OnAgentExecute`, `TTermManager.OnExit`, `TTermManager.OnRoute`.

Because the package registers its components and property editors at design time (`OllamaKitRegister`), the components and multiline editors for `Welcome`, `SystemPrompt`, `Description` and `ParametersJson` are available immediately after installation.

---

## Installation

1. Open the `ollamakit` package in Lazarus and select the **Install Package** button.

---

## License

MIT License — see the `LICENSE` file for details.