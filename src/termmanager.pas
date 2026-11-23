//-----------------------------------------------------------------------------------
//  OllamaKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit TermManager;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, DateUtils, Process, fpjson, jsonparser, TypInfo, StringHelper,
  OllamaManager, OllamaAgent, AgentConfig{$IFDEF WINDOWS}, Windows{$ENDIF};

type
  // Classification of a single input line
  TTermInputKind = (tikEmpty, tikBuiltin, tikCommand, tikAgent);

  // Standard 16-color Windows console palette
  TConsoleColor = (
    // Standard colors, 0 to 7
    ccBlack, ccRed, ccGreen, ccYellow, ccBlue, ccMagenta, ccCyan, ccLightGray,
    // Bright colors, 8 to 15
    ccDarkGray, ccLightRed, ccLightGreen, ccLightYellow, ccLightBlue,
    ccLightMagenta, ccLightCyan, ccWhite
    );

  // Semantic color roles used by terminal output
  TTermColor = (tcDefault, tcDim, tcWelcome, tcThinkingBadge, tcToolBadge, tcErrorBadge, tcWarnBadge,
    tcPromptInput, tcLog, tcMarkdownMarker, tcMarkdownBold, tcMarkdownItalic, tcMarkdownStrike,
    tcMarkdownCode, tcMarkdownFencedCode, tcMarkdownHighlight, tcMarkdownHeading, tcMarkdownQuote, tcMarkdownList);

  TTermRouteEvent = procedure(Sender: TObject; const ALine, APayload: string; var AKind: TTermInputKind; var AAllow: boolean) of object;
  TTermOutputEvent = procedure(Sender: TObject; const AText: string; AIsStderr: boolean) of object;
  TTermAgentEvent = procedure(Sender: TObject; const AText: string) of object;
  TTermExitEvent = procedure(Sender: TObject; AExitCode: integer) of object;

type
  // Foreground and background pair for a single badge style
  TConsoleColorPair = class(TPersistent)
  private
    FBackground: TConsoleColor;
    FForeground: TConsoleColor;
  public
    constructor Create;
    procedure Assign(Source: TPersistent); override;
  published
    // Background color, ccBlack keeps the terminal default background
    property Background: TConsoleColor read FBackground write FBackground default ccBlack;
    // Foreground color for badge text
    property Foreground: TConsoleColor read FForeground write FForeground default ccWhite;
  end;

  // Colors used to highlight Markdown syntax in model responses
  TMarkdownColorScheme = class(TPersistent)
  private
    FMarker: TConsoleColor;
    FBold: TConsoleColor;
    FItalic: TConsoleColor;
    FStrikethrough: TConsoleColor;
    FInlineCode: TConsoleColor;
    FFencedCode: TConsoleColor;
    FHighlight: TConsoleColor;
    FHeading: TConsoleColor;
    FQuote: TConsoleColor;
    FListMarker: TConsoleColor;
  public
    constructor Create;
    procedure Assign(Source: TPersistent); override;
  published
    // Markdown delimiters such as **, ` and ##
    property Marker: TConsoleColor read FMarker write FMarker default ccDarkGray;
    // Bold text
    property Bold: TConsoleColor read FBold write FBold default ccWhite;
    // Italic text
    property Italic: TConsoleColor read FItalic write FItalic default ccLightCyan;
    // Strikethrough text
    property Strikethrough: TConsoleColor read FStrikethrough write FStrikethrough default ccDarkGray;
    // Inline code text
    property InlineCode: TConsoleColor read FInlineCode write FInlineCode default ccLightGreen;
    // Highlighted text
    property Highlight: TConsoleColor read FHighlight write FHighlight default ccLightYellow;
    // Heading text
    property Heading: TConsoleColor read FHeading write FHeading default ccLightCyan;
    // Blockquote text
    property Quote: TConsoleColor read FQuote write FQuote default ccLightGray;
    // List markers
    property ListMarker: TConsoleColor read FListMarker write FListMarker default ccLightBlue;
    // Fenced code block text
    property FencedCode: TConsoleColor read FFencedCode write FFencedCode default ccLightGreen;
  end;

  // Full color palette used by TermManager output
  TTermColorScheme = class(TPersistent)
  private
    FDefaultText: TConsoleColor;
    FThinkingText: TConsoleColor;
    FWelcomeBadge: TConsoleColorPair;
    FThinkingBadge: TConsoleColorPair;
    FToolBadge: TConsoleColorPair;
    FErrorBadge: TConsoleColorPair;
    FWarnBadge: TConsoleColorPair;
    FPromptInput: TConsoleColorPair;
    FLog: TConsoleColorPair;
    FMarkdown: TMarkdownColorScheme;
    procedure SetWelcomeBadge(const AValue: TConsoleColorPair);
    procedure SetThinkingBadge(const AValue: TConsoleColorPair);
    procedure SetToolBadge(const AValue: TConsoleColorPair);
    procedure SetErrorBadge(const AValue: TConsoleColorPair);
    procedure SetWarnBadge(const AValue: TConsoleColorPair);
    procedure SetPromptInput(const AValue: TConsoleColorPair);
    procedure SetLog(const AValue: TConsoleColorPair);
    procedure SetMarkdown(const AValue: TMarkdownColorScheme);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Assign(Source: TPersistent); override;
  published
    // Color of regular output such as prompt, model answers and command output
    property DefaultText: TConsoleColor read FDefaultText write FDefaultText default ccWhite;
    // Color of agent thinking text, shown between thinking badges
    property ThinkingText: TConsoleColor read FThinkingText write FThinkingText default ccLightGray;
    // Badge style for the welcome banner, empty background keeps terminal default
    property WelcomeBadge: TConsoleColorPair read FWelcomeBadge write SetWelcomeBadge;
    // Badge style for the [Thinking] label
    property ThinkingBadge: TConsoleColorPair read FThinkingBadge write SetThinkingBadge;
    // Badge style for tool call labels like [exec_command: dir]
    property ToolBadge: TConsoleColorPair read FToolBadge write SetToolBadge;
    // Badge style for error messages
    property ErrorBadge: TConsoleColorPair read FErrorBadge write SetErrorBadge;
    // Badge style for warning messages such as max steps reached
    property WarnBadge: TConsoleColorPair read FWarnBadge write SetWarnBadge;
    // Style for the entire user input prompt and entered text
    property PromptInput: TConsoleColorPair read FPromptInput write SetPromptInput;
    // Style for agent log messages
    property Log: TConsoleColorPair read FLog write SetLog;
    property Markdown: TMarkdownColorScheme read FMarkdown write SetMarkdown;
  end;

  // Shell history sharing options passed to the agent as context prelude
  TAgentShellHistory = class(TPersistent)
  private
    FEnabled: boolean;
    FMaxEntries: integer;
    FMaxOutputBytes: integer;
    FClearOnAgentRun: boolean;
  public
    constructor Create;
    procedure Assign(Source: TPersistent); override;
  published
    // Share recent shell commands and their output with the agent
    property Enabled: boolean read FEnabled write FEnabled default False;
    // Maximum number of shell commands kept in the shared log
    property MaxEntries: integer read FMaxEntries write FMaxEntries default 10;
    // Maximum bytes captured per command output in the shared log
    property MaxOutputBytes: integer read FMaxOutputBytes write FMaxOutputBytes default 2048;
    // Clear the shell log after it has been passed to the agent
    property ClearOnAgentRun: boolean read FClearOnAgentRun write FClearOnAgentRun default True;
  end;

  TCustomTermManager = class(TComponent)
  private
    FPath: string;
    FPrompt: string;
    FStartupPrompt: string;

    FWelcome: TCaption;
    // Label printed before agent thinking block, followed by a newline
    FThinkingLabel: TCaption;
    // When False only the label is printed, thinking text is suppressed
    FShowThinking: boolean;
    // Label printed on its own line before a tool call, {name} and {args} placeholders
    FToolCallLabel: TCaption;
    // True when last written char was CR or LF, used to keep prompt on fresh line
    FLastCharWasNewLine: boolean;
    // Remove emoji and symbol chars that console fonts cannot render
    FStripEmoji: boolean;
    // Colorize badges and thinking text when console supports attributes
    FColorOutput: boolean;
    // Semantic color palette for output
    FColors: TTermColorScheme;
    // Label used in the {info} badge when no model is selected
    FDefaultModelLabel: TCaption;
    FBuiltinCommands: TStringList;
    FHistory: TStringList;
    FHistoryMax: integer;
    FShellExec: string;
    FCommandTimeout: integer;
    // Maximum captured bytes from agent exec_command, truncated with notice
    FMaxCaptureBytes: integer;
    // Timeout in milliseconds for agent exec_command, zero means no limit
    FAgentCommandTimeout: integer;
    FUsePrefixes: boolean;
    FSearchPath: boolean;
    FRunning: boolean;
    FLastExitCode: integer;
    // Attached agent used to answer agent-classified input
    FAgent: TCustomOllamaAgent;
    // Prevents restored output from being recorded again
    FRestoringChat: boolean;
    // Previous agent handlers, restored when agent is detached
    FPrevAgentOnChunk: TAgentChunkEvent;
    FPrevAgentOnLog: TAgentLogEvent;
    FPrevAgentOnContextUsage: TAgentContextUsageEvent;
    FPrevAgentOnThinking: TAgentThinkingEvent;
    FPrevAgentOnToolCall: TAgentToolCallEvent;
    FPrevAgentOnToolResult: TAgentToolResultEvent;
    FPrevAgentOnFinish: TAgentFinishEvent;
    FPrevAgentOnExecCommand: TAgentExecCommandEvent;
    FPrevAgentOnAskUser: TAgentAskUserEvent;
    // True while writing agent thinking before the first content chunk
    FInThinking: boolean;
    // Set to True when the model produced its first chunk of any kind
    FFirstChunkSeen: boolean;
    // Set to True when the model called the finish tool
    FFinishToolCalled: boolean;
    // Shown when the agent is slow but the server is reachable
    FWaitSlowHint: TCaption;
    // Shown when the agent is slow and the server is unreachable
    FWaitServerDownHint: TCaption;
    // Delay in ms before checking server reachability, zero disables the check
    FWaitCheckDelayMs: integer;
    // Shell history sharing options for the agent context prelude
    FShellHistory: TAgentShellHistory;
    // Log entries encoded as "C\x01cmd\x01output" or "E\x01cmd\x01output"
    FShellLog: TStringList;
    // True while collecting output of the current command
    FCapturing: boolean;
    FCaptureCommand: string;
    FCaptureOutput: string;
    FCaptureError: boolean;
    FOnRoute: TTermRouteEvent;
    FOnOutput: TTermOutputEvent;
    FOnAgentExecute: TTermAgentEvent;
    FOnExit: TTermExitEvent;
    // Ollama operation tracking for synchronous console commands
    FOllamaOpDone: boolean;
    FOllamaOpKind: TOllamaErrorKind;
    FOllamaOpError: string;
    FOllamaWaitModel: string;
    FOllamaPullPct: integer;
    FOllamaPullLastStep: integer;
    FStdOutPending: rawbytestring;
    FStdErrPending: rawbytestring;
    FSuppressChatOutput: boolean;
    FPendingOutputStart: SizeInt;
    FPendingScreenRow: integer;
    FPendingScreenCol: integer;
    FLastInputScreenCleared: boolean;
    FCurrentOutputMark: boolean;
    {$IFDEF WINDOWS}
    FDefaultConsoleAttr: Word;
    FDefaultConsoleAttrCaptured: boolean;
    {$ENDIF}
    // Holds an incomplete Markdown line between streamed chunks
    FMarkdownPending: string;
    // True while the response is inside a fenced code block
    FMarkdownFencedCode: boolean;
    FMarkdownFenceChar: char;
    // Updates the native terminal window title with the current directory
    procedure UpdateConsoleTitle;
    // Sets the working directory and synchronizes the agent root path
    procedure SetPath(const AValue: string);
    // Assigns the agent and synchronizes its terminal state
    procedure SetAgent(const AValue: TCustomOllamaAgent);
    // Assigns the command history
    procedure SetHistory(const AValue: TStringList);
    // Switches the active agent chat and restores its terminal state
    function SwitchActiveChat(ADelta: integer): boolean;
    // Moves the active chat in the list
    function MoveActiveChat(ADelta: integer): boolean;
    // Appends terminal text to the active chat transcript
    procedure AppendChatOutput(const AText: string);
    // Sets the terminal color scheme
    procedure SetColors(const AValue: TTermColorScheme);
    // Assigns the shell command history
    procedure SetShellHistory(const AValue: TAgentShellHistory);
    // Handles short and full help commands
    procedure HandleHelpCommand(AShort: boolean);
    // Handles set <name> <value>
    procedure HandleSetCommand(const AArg: string);
    // Handles get <name>
    procedure HandleGetCommand(const AArg: string);
    // Handles models, queries OllamaManager for available models
    procedure HandleModelsCommand(const AArg: string);
    // Handles set term.<name> <value>
    procedure HandleTermSet(const AName, AValue: string);
    // Handles get term.<name>
    procedure HandleTermGet(const AName: string);
    // Dispatches ollama <subcommand> to the API-backed implementation
    procedure HandleOllamaCommand(const AArg: string);
    // Handles the ollama list command
    procedure HandleOllamaList;
    // Handles the ollama ps command
    procedure HandleOllamaPs;
    // Handles the ollama show command for a model
    procedure HandleOllamaShow(const AModel: string);
    // Handles pulling a model from the Ollama registry
    procedure HandleOllamaPull(const AModel: string);
    // Handles removing a local model
    procedure HandleOllamaRm(const AModel: string);
    // Handles stopping a running model
    procedure HandleOllamaStop(const AModel: string);
    // Handles loading a model into memory
    procedure HandleOllamaLoad(const AModel: string);
    // Handles unloading a model from memory
    procedure HandleOllamaUnload(const AModel: string);
    // Handles copying a model to another name
    procedure HandleOllamaCopy(const ASource, ADest: string);
    // Handles creating a model from a Modelfile
    procedure HandleOllamaCreate(const AName, AFile: string);
    // Handles displaying the Ollama version
    procedure HandleOllamaVersion;
    // Temporary event handlers used while a command is in flight
    procedure HandleOllamaModelsRefreshed(Sender: TObject; const Models: TStringList);
    // Handles an Ollama operation error
    procedure HandleOllamaError(Sender: TObject; Kind: TOllamaErrorKind; const ModelName, Msg: string);
    // Handles model download progress updates
    procedure HandleOllamaPullProgress(Sender: TObject; const ModelName: string; Percent: integer);
    // Pumps sync events until the pending ollama operation finishes or times out
    function WaitOllamaOp(ATimeoutMs: integer): boolean;
    // Reads a small text file as string, returns empty when read fails
    function ReadSmallTextFile(const APath: string): string;
    // Formats a byte count as human-readable string like "23.4 GB"
    function BytesToHumanText(const ABytes: int64): string;
    // Restores terminal input history from the chat conversation when missing
    procedure RestoreTerminalHistory;
    // Removes the last terminal input and its conversation exchange
    function RemoveLastInput: boolean;
    // Asks the user to confirm chat deletion
    function ConfirmDeleteChat(const AChatName: string): boolean;
  protected
    // Clears agent reference when it is removed at runtime
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    // Applies a semantic color to subsequent output, no-op on non-Windows
    procedure SetColor(AColor: TTermColor); virtual;
    procedure ReplayChatOutput(const AText: string);
    // Returns Path or process current directory when Path is empty
    function GetEffectivePath: string; virtual;
    // Returns prompt text with {path} placeholder replaced by Path
    function GetPromptText: string; virtual;
    // Fires route event so host can approve or change classification
    procedure DoRoute(const ALine, APayload: string; var AKind: TTermInputKind; var AAllow: boolean); virtual;
    // Writes text to console and fires output event
    procedure DoOutput(const AText: string; AIsStderr: boolean); virtual;
    // Fires agent execution event; host runs agent synchronously inside
    procedure DoAgentExecute(const AText: string); virtual;
    // Fires exit event when main loop terminates
    procedure DoExit(AExitCode: integer); virtual;
    // Classifies input using prefixes, builtins and external search
    function ClassifyLine(const ALine: string; out APayload: string): TTermInputKind; virtual;
    // Handles builtin commands like cd, cls, help, exit
    procedure HandleBuiltin(const ALine: string); virtual;
    // Runs external command, streams output, returns exit code
    function ExecuteCommand(const ACommand: string): integer; virtual;
    // Reads one line from user with editing and history
    function ReadLine: string; virtual;
    // Appends a line to history respecting HistoryMax
    procedure AddToHistory(const ALine: string); virtual;
    // Returns True if name is a known shell builtin or PATH executable
    function IsExternalCommand(const AName: string): boolean; virtual;
    // Converts OEM-encoded shell output to UTF-8 and prints it
    procedure PumpOutput(const AData: rawbytestring; AIsStderr: boolean; AFinal: boolean = False); virtual;
    // Redirects agent streamed chunks to console output
    procedure HandleAgentChunk(Sender: TObject; const AText: string);
    // Closes the active thinking block with a trailing blank line
    procedure CloseThinking;
    // Prints agent log lines in thinking color
    procedure HandleAgentLog(Sender: TObject; const AText: string);
    // Refreshes context indicators after agent usage changes
    procedure HandleAgentContextUsage(Sender: TObject; AUsed, ATotal: integer);
    // Redirects agent thinking chunks to console output with a label
    procedure HandleAgentThinking(Sender: TObject; const AText: string);
    // Prints tool call label with surrounding blank lines
    procedure HandleAgentToolCall(Sender: TObject; const AName, AArgsJson: string);
    // Forwards tool result to host handler without console output
    procedure HandleAgentToolResult(Sender: TObject; const AName, AResult: string);
    // Finalizes console line after agent run
    procedure HandleAgentFinish(Sender: TObject; AReason: TAgentFinishReason; const AAnswer, AErrorMsg: string);
    // Records a shell command and its output for sharing with the agent
    procedure RecordShellOperation(const ACommand, AOutput: string; AIsError: boolean); virtual;
    // Builds formatted shell context string from the recorded operations
    function BuildShellContext: string; virtual;
    // Returns True for cls, clear, exit and quit which should not be logged
    function IsMetaCommand(const ACommand: string): boolean; virtual;
    // Returns True for commands that control the chat interface
    function IsChatControlCommand(const ACommand: string): boolean; virtual;
    // Executes agent shell command through configured shell and returns output
    procedure HandleAgentExecCommand(Sender: TObject; const ACommand: string; var AResult: string; var AAllow: boolean);
    // Prompts the user with a question and returns the typed answer
    procedure HandleAgentAskUser(Sender: TObject; const AQuestion: string; var AAnswer: string; var AAllow: boolean);
    // Processes streamed model output with Markdown syntax highlighting
    procedure ProcessMarkdownChunk(const AText: string; AFinal: boolean = False);
    // Processes one complete Markdown line
    procedure ProcessMarkdownLine(const ALine: string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Starts the interactive loop and blocks until exit
    procedure Run; virtual;
    // Requests the loop to stop after current iteration
    procedure Stop; virtual;
    // Runs shell command capturing output as UTF-8, returns combined stdout and stderr
    function ExecuteCommandCapture(const ACommand: string; out AExitCode: integer; ATimeoutMs: integer = -1): string; virtual;
    // Writes raw text without line ending, flushes for streaming output
    procedure WriteText(const AText: string; AIsStderr: boolean = False); virtual;
    // Writes text followed by a line ending, flushes immediately
    procedure WriteLine(const AText: string; AIsStderr: boolean = False); virtual;
    // Returns multi-line current values of term.* properties
    function FormatTermConfig: string; virtual;
    // Restores terminal buffers and output of the active chat
    procedure RestoreActiveChat;

    property Path: string read FPath write SetPath;
    property Prompt: string read FPrompt write FPrompt;
    property StartupPrompt: string read FStartupPrompt write FStartupPrompt;
    property Welcome: TCaption read FWelcome write FWelcome;
    property ThinkingLabel: TCaption read FThinkingLabel write FThinkingLabel;
    property ShowThinking: boolean read FShowThinking write FShowThinking default True;
    property ToolCallLabel: TCaption read FToolCallLabel write FToolCallLabel;
    property StripEmoji: boolean read FStripEmoji write FStripEmoji default True;
    property ColorOutput: boolean read FColorOutput write FColorOutput default True;
    property Colors: TTermColorScheme read FColors write SetColors;
    property DefaultModelLabel: TCaption read FDefaultModelLabel write FDefaultModelLabel;
    property WaitSlowHint: TCaption read FWaitSlowHint write FWaitSlowHint;
    property WaitServerDownHint: TCaption read FWaitServerDownHint write FWaitServerDownHint;
    property WaitCheckDelayMs: integer read FWaitCheckDelayMs write FWaitCheckDelayMs default 10000;
    property BuiltinCommands: TStringList read FBuiltinCommands;
    property HistoryMax: integer read FHistoryMax write FHistoryMax default 200;
    property ShellExec: string read FShellExec write FShellExec;
    property CommandTimeout: integer read FCommandTimeout write FCommandTimeout default 0;
    property MaxCaptureBytes: integer read FMaxCaptureBytes write FMaxCaptureBytes default 65536;
    property AgentCommandTimeout: integer read FAgentCommandTimeout write FAgentCommandTimeout default 30000;
    property UsePrefixes: boolean read FUsePrefixes write FUsePrefixes default True;
    property ShellHistory: TAgentShellHistory read FShellHistory write SetShellHistory;
    property SearchPath: boolean read FSearchPath write FSearchPath default True;
    property LastExitCode: integer read FLastExitCode;
    property History: TStringList read FHistory write SetHistory;
    property Running: boolean read FRunning;
    property OnRoute: TTermRouteEvent read FOnRoute write FOnRoute;
    property OnOutput: TTermOutputEvent read FOnOutput write FOnOutput;
    property OnAgentExecute: TTermAgentEvent read FOnAgentExecute write FOnAgentExecute;
    property OnExit: TTermExitEvent read FOnExit write FOnExit;
    property Agent: TCustomOllamaAgent read FAgent write SetAgent;
  end;

  TTermManager = class(TCustomTermManager)
  published
    // Working directory for shell commands and agent file tools, empty uses process cwd
    property Path;
    // Prompt template, supports {path}, {model}, {chat}, {chatindex}, context and usage placeholders
    property Prompt;
    // Multi-line banner printed once before the first prompt
    property Welcome;
    // Line printed before agent reasoning block, for example [Thinking]
    property ThinkingLabel;
    // Show agent reasoning text; when False only ThinkingLabel is printed
    property ShowThinking;
    // Line printed before each tool call, supports {name}, {args} and JSON field placeholders like {command}
    property ToolCallLabel;
    // Strip emoji and unsupported symbol ranges that plain console fonts cannot render
    property StripEmoji;
    // Colorize badges and thinking text when console supports attributes
    property ColorOutput;
    // Semantic color palette for output, expand to customize each role
    property Colors;
    // Label shown in the {info} badge when no model is selected
    property DefaultModelLabel;
    // Hint shown when the agent waits longer than a second with reachable server
    property WaitSlowHint;
    // Hint shown when the agent waits longer than a second with unreachable server
    property WaitServerDownHint;
    // Delay in ms before checking server reachability, 0 disables the check
    property WaitCheckDelayMs;
    // Commands executed internally without invoking the shell, extend to add your own
    property BuiltinCommands;
    // Maximum number of input lines kept in history, oldest are dropped first
    property HistoryMax;
    // Shell executable used to run external commands and agent exec_command, defaults to cmd.exe
    property ShellExec;
    // Timeout in milliseconds for user-typed external commands, zero means no limit
    property CommandTimeout;
    // Cap on bytes captured from agent exec_command, excess is truncated with a notice
    property MaxCaptureBytes;
    // Timeout in milliseconds for agent exec_command, zero means no limit, default 30 seconds
    property AgentCommandTimeout;
    // Enable ! and ? prefixes to force command or agent routing respectively
    property UsePrefixes;
    // Pass recent shell commands to the agent, expand to adjust log limits
    property ShellHistory;
    // Also detect PATH executables and known shell builtins when classifying input
    property SearchPath;
    // Fires before routing each input, host can approve, reject or reclassify it
    property OnRoute;
    // Fires for every chunk of command output, useful for logging or filtering
    property OnOutput;
    // Fires when input is classified as agent text and no Agent is attached
    property OnAgentExecute;
    // Fires when the interactive loop terminates, receives last command exit code
    property OnExit;
    // Agent component that handles agent-classified input, leave empty to disable
    property Agent;
  end;

implementation

const
  INTERACTIVE_COMMANDS =
    '|del|erase|rd|rmdir|ssh|ssh.exe|ssh-keygen|ssh-keygen.exe|scp|scp.exe|sftp|sftp.exe|' +
    'ftp|ftp.exe|telnet|telnet.exe|rlogin|rlogin.exe|mosh|plink|putty|vim|vim.exe|vi|nano|nano.exe|emacs|emacs.exe|ne|micro|joe|' +
    'less|less.exe|more|more.exe|man|man.exe|most|bat|top|htop|btop|atop|glances|nmon|watch|' +
    'tmux|screen|mc|ranger|nnn|lf|yazi|python|python.exe|python3|python3.exe|ipython|ipython.exe|' +
    'node|node.exe|deno|bun|irb|pry|ghci|lua|lua.exe|psql|psql.exe|mysql|mysql.exe|sqlite3|mongosh|redis-cli|' +
    'sqlcmd|sqlcmd.exe|gdb|gdb.exe|lldb|fdb|debug|diskpart|diskpart.exe|wsl|wsl.exe|powershell|powershell.exe|pwsh|pwsh.exe|' +
    'cmd|cmd.exe|sudo|su|passwd|doas|login|gpg|openssl|ollama|ollama.exe|';

  // Buffer type for piping output with zero-initialization
type
  TTermBuffer = array[0..4095] of byte;

// Forward declarations for helpers used before their definition
procedure ClearScreen; forward;
function CheckAndConsumeCancel: boolean; forward;
{$IFDEF WINDOWS}
procedure WriteUtf8ToHandle(AHandle: THandle; const ABytes: RawByteString); forward;
{$ENDIF}

type
  TShellFamily = (sfUnknown, sfCmd, sfPowerShell, sfUnix);

// Detect the shell family by executable name
function DetectShellFamily(const AShell: string): TShellFamily;
var
  S: string;
begin
  S := LowerCase(ExtractFileName(Trim(AShell)));

  if (S = 'cmd.exe') or (S = 'cmd') or (S = 'command.com') then
    Exit(sfCmd);

  if (S = 'powershell.exe') or (S = 'powershell') or (S = 'pwsh.exe') or (S = 'pwsh') then
    Exit(sfPowerShell);

  if (S = 'sh') or (S = 'bash') or (S = 'zsh') or (S = 'dash') or (S = 'fish') or (S = 'ksh') then
    Exit(sfUnix);

  Result := sfUnknown;
end;

// Encode a PowerShell command as Base64 UTF-16LE
function EncodePowerShellCommand(const ACommand: string): string;
const
  Base64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  UnicodeText: unicodestring = '';
  Data: rawbytestring = '';
  I, J: integer;
  B0, B1, B2: byte;
begin
  UnicodeText := UTF8Decode(ACommand);
  SetLength(Data, Length(UnicodeText) * 2);

  // Convert UTF-16 code units to little-endian bytes
  for I := 1 to Length(UnicodeText) do
  begin
    Data[(I - 1) * 2 + 1] := ansichar(Ord(UnicodeText[I]) and $FF);
    Data[(I - 1) * 2 + 2] := ansichar((Ord(UnicodeText[I]) shr 8) and $FF);
  end;

  Result := string.Empty;
  I := 1;

  // Encode the UTF-16LE data as Base64
  while I <= Length(Data) do
  begin
    B0 := Ord(Data[I]);
    B1 := 0;
    B2 := 0;

    if I + 1 <= Length(Data) then
      B1 := Ord(Data[I + 1]);
    if I + 2 <= Length(Data) then
      B2 := Ord(Data[I + 2]);

    J := Length(Result);
    SetLength(Result, J + 4);

    Result[J + 1] := Base64Chars[(B0 shr 2) + 1];
    Result[J + 2] := Base64Chars[(((B0 and 3) shl 4) or (B1 shr 4)) + 1];

    if I + 1 <= Length(Data) then
      Result[J + 3] := Base64Chars[(((B1 and 15) shl 2) or (B2 shr 6)) + 1]
    else
      Result[J + 3] := '=';

    if I + 2 <= Length(Data) then
      Result[J + 4] := Base64Chars[(B2 and 63) + 1]
    else
      Result[J + 4] := '=';

    Inc(I, 3);
  end;
end;

// Returns True if path contains drive letter or starts with path delimiter
function IsAbsolutePath(const APath: string): boolean;
begin
  {$IFDEF WINDOWS}
  Result := (Length(APath) >= 2) and (APath[2] = ':');
  {$ELSE}
  Result := (Length(APath) >= 1) and (APath[1] = PathDelim);
  {$ENDIF}
end;

// Returns the byte position before the previous character, UTF-8 aware
function Utf8PrevPos(const S: string; APos: integer): integer;
begin
  Result := APos - 1;
  while (Result > 0) and ((byte(S[Result + 1]) and $C0) = $80) do
    Dec(Result);
end;

function Utf8NextPos(const S: string; APos: integer): integer;
var
  C: byte;
begin
  if (APos < 1) or (APos > Length(S)) then
    Exit(APos);
  C := byte(S[APos]);
  if C < $80 then Exit(APos + 1);
  if C < $E0 then Exit(APos + 2);
  if C < $F0 then Exit(APos + 3);
  Result := APos + 4;
end;

function Utf8CharCount(const S: string): integer;
var
  I: integer;
begin
  Result := 0;
  I := 1;
  while I <= Length(S) do
  begin
    I := Utf8NextPos(S, I);
    Inc(Result);
  end;
end;

// Returns UTF-8 bytes tagged with CP_UTF8 to avoid implicit recoding
function WideCharToUtf8(const C: widechar): rawbytestring;
var
  U: unicodestring;
begin
  U := C;
  Result := UTF8Encode(U);
  SetCodePage(Result, CP_UTF8, False);
end;

function IsValidUTF8(const S: rawbytestring): boolean;
var
  I, N, J: SizeInt;
  B, B2: byte;
begin
  Result := False;
  I := 1;

  while I <= Length(S) do
  begin
    B := Ord(S[I]);

    if B <= $7F then
      N := 1
    else if (B >= $C2) and (B <= $DF) then
      N := 2
    else if (B >= $E0) and (B <= $EF) then
      N := 3
    else if (B >= $F0) and (B <= $F4) then
      N := 4
    else
      Exit;

    if I + N - 1 > Length(S) then
      Exit;

    for J := 1 to N - 1 do
    begin
      B2 := Ord(S[I + J]);

      if (B2 and $C0) <> $80 then
        Exit;

      if (J = 1) and (((B = $E0) and (B2 < $A0)) or ((B = $ED) and (B2 >= $A0)) or ((B = $F0) and (B2 < $90)) or
        ((B = $F4) and (B2 > $8F))) then
        Exit;
    end;

    Inc(I, N);
  end;

  Result := True;
end;

// Removes emoji and symbol ranges that plain console fonts cannot render
function StripEmojiChars(const AText: string): string;
var
  Wide, Filtered: unicodestring;
  I, J: integer;
  Code: cardinal;
begin
  Wide := UTF8Decode(AText);
  Filtered := '';
  SetLength(Filtered, Length(Wide));
  J := 0;
  for I := 1 to Length(Wide) do
  begin
    Code := Ord(Wide[I]);
    if (Code >= $D800) and (Code <= $DFFF) then
      Continue;
    if (Code >= $2300) and (Code <= $23FF) then
      Continue;
    if (Code >= $2600) and (Code <= $27BF) then
      Continue;
    if (Code >= $2B00) and (Code <= $2BFF) then
      Continue;
    if Code = $200D then
      Continue;
    if (Code >= $FE00) and (Code <= $FE0F) then
      Continue;
    Inc(J);
    Filtered[J] := Wide[I];
  end;
  SetLength(Filtered, J);
  Result := UTF8Encode(Filtered);
end;

// Converts interactive cmd FOR variables to batch-file syntax
function PrepareCmdBatchScript(const ACommand: string): string;
var
  I: integer;
begin
  Result := string.Empty;
  I := 1;

  while I <= Length(ACommand) do
  begin
    if (ACommand[I] = '%') and ((I = 1) or (ACommand[I - 1] <> '%')) and (I < Length(ACommand)) and
      (ACommand[I + 1] in ['A'..'Z', 'a'..'z']) and ((I + 2 > Length(ACommand)) or not (ACommand[I + 2] in
      ['A'..'Z', 'a'..'z', '0'..'9', '_', '%'])) then
    begin
      Result := Result + '%%' + ACommand[I + 1];
      Inc(I, 2);
      Continue;
    end
    else
      Result := Result + ACommand[I];

    Inc(I);
  end;
end;

// Converts a color name to the console palette
function TryParseTermColor(const AValue: string; out AColor: TConsoleColor): boolean;
begin
  Result := True;
  case LowerCase(Trim(AValue)) of
    'black': AColor := ccBlack;
    'red': AColor := ccRed;
    'green': AColor := ccGreen;
    'yellow': AColor := ccYellow;
    'blue': AColor := ccBlue;
    'magenta': AColor := ccMagenta;
    'cyan': AColor := ccCyan;
    'gray', 'lightgray': AColor := ccLightGray;
    'darkgray': AColor := ccDarkGray;
    'lightred': AColor := ccLightRed;
    'lightgreen': AColor := ccLightGreen;
    'lightyellow': AColor := ccLightYellow;
    'lightblue': AColor := ccLightBlue;
    'lightmagenta': AColor := ccLightMagenta;
    'lightcyan': AColor := ccLightCyan;
    'white': AColor := ccWhite;
    else
      Result := False;
  end;
end;

// Converts a console palette value to its short name
function TermColorName(AColor: TConsoleColor): string;
begin
  case AColor of
    ccBlack: Result := 'black';
    ccRed: Result := 'red';
    ccGreen: Result := 'green';
    ccYellow: Result := 'yellow';
    ccBlue: Result := 'blue';
    ccMagenta: Result := 'magenta';
    ccCyan: Result := 'cyan';
    ccLightGray: Result := 'gray';
    ccDarkGray: Result := 'darkgray';
    ccLightRed: Result := 'lightred';
    ccLightGreen: Result := 'lightgreen';
    ccLightYellow: Result := 'lightyellow';
    ccLightBlue: Result := 'lightblue';
    ccLightMagenta: Result := 'lightmagenta';
    ccLightCyan: Result := 'lightcyan';
    ccWhite: Result := 'white';
    else
      ;
  end;
end;

{ TAgentShellHistory }

constructor TAgentShellHistory.Create;
begin
  inherited Create;
  FEnabled := False;
  FMaxEntries := 10;
  FMaxOutputBytes := 2048;
  FClearOnAgentRun := True;
end;

procedure TAgentShellHistory.Assign(Source: TPersistent);
var
  Src: TAgentShellHistory;
begin
  if Source is TAgentShellHistory then
  begin
    Src := TAgentShellHistory(Source);
    FEnabled := Src.FEnabled;
    FMaxEntries := Src.FMaxEntries;
    FMaxOutputBytes := Src.FMaxOutputBytes;
    FClearOnAgentRun := Src.FClearOnAgentRun;
  end
  else
    inherited Assign(Source);
end;

{ TConsoleColorPair }

constructor TConsoleColorPair.Create;
begin
  inherited Create;
  FBackground := ccBlack;
  FForeground := ccWhite;
end;

procedure TConsoleColorPair.Assign(Source: TPersistent);
var
  Src: TConsoleColorPair;
begin
  if Source is TConsoleColorPair then
  begin
    Src := TConsoleColorPair(Source);
    FBackground := Src.FBackground;
    FForeground := Src.FForeground;
  end
  else
    inherited Assign(Source);
end;

{ TMarkdownColorScheme }

constructor TMarkdownColorScheme.Create;
begin
  inherited Create;
  FMarker := ccDarkGray;
  FBold := ccLightBlue;
  FItalic := ccLightMagenta;
  FStrikethrough := ccDarkGray;
  FInlineCode := ccLightGreen;
  FHighlight := ccLightYellow;
  FHeading := ccLightYellow;
  FQuote := ccLightGray;
  FListMarker := ccLightBlue;
  FFencedCode := ccLightGray;
end;

procedure TMarkdownColorScheme.Assign(Source: TPersistent);
var
  Src: TMarkdownColorScheme;
begin
  if Source is TMarkdownColorScheme then
  begin
    Src := TMarkdownColorScheme(Source);
    FMarker := Src.FMarker;
    FBold := Src.FBold;
    FItalic := Src.FItalic;
    FStrikethrough := Src.FStrikethrough;
    FInlineCode := Src.FInlineCode;
    FHighlight := Src.FHighlight;
    FHeading := Src.FHeading;
    FQuote := Src.FQuote;
    FListMarker := Src.FListMarker;
    FFencedCode := Src.FFencedCode;
  end
  else
    inherited Assign(Source);
end;

{ TTermColorScheme }

constructor TTermColorScheme.Create;
begin
  inherited Create;
  FDefaultText := ccWhite;
  FThinkingText := ccLightGray;
  FWelcomeBadge := TConsoleColorPair.Create;
  FWelcomeBadge.Background := ccBlack;
  FWelcomeBadge.Foreground := ccWhite;
  FThinkingBadge := TConsoleColorPair.Create;
  FThinkingBadge.Background := ccDarkGray;
  FThinkingBadge.Foreground := ccWhite;
  FToolBadge := TConsoleColorPair.Create;
  FToolBadge.Background := ccBlue;
  FToolBadge.Foreground := ccWhite;
  FErrorBadge := TConsoleColorPair.Create;
  FErrorBadge.Background := ccRed;
  FErrorBadge.Foreground := ccWhite;
  FWarnBadge := TConsoleColorPair.Create;
  FWarnBadge.Background := ccYellow;
  FWarnBadge.Foreground := ccWhite;
  FPromptInput := TConsoleColorPair.Create;
  FPromptInput.Background := ccBlack;
  FPromptInput.Foreground := ccWhite;
  FLog := TConsoleColorPair.Create;
  FLog.Background := ccBlack;
  FLog.Foreground := ccCyan;
  FMarkdown := TMarkdownColorScheme.Create;
end;

destructor TTermColorScheme.Destroy;
begin
  FWelcomeBadge.Free;
  FThinkingBadge.Free;
  FToolBadge.Free;
  FErrorBadge.Free;
  FWarnBadge.Free;
  FPromptInput.Free;
  FLog.Free;
  FMarkdown.Free;
  inherited Destroy;
end;

procedure TTermColorScheme.SetWelcomeBadge(const AValue: TConsoleColorPair);
begin
  FWelcomeBadge.Assign(AValue);
end;

procedure TTermColorScheme.SetThinkingBadge(const AValue: TConsoleColorPair);
begin
  FThinkingBadge.Assign(AValue);
end;

procedure TTermColorScheme.SetToolBadge(const AValue: TConsoleColorPair);
begin
  FToolBadge.Assign(AValue);
end;

procedure TTermColorScheme.SetErrorBadge(const AValue: TConsoleColorPair);
begin
  FErrorBadge.Assign(AValue);
end;

procedure TTermColorScheme.SetWarnBadge(const AValue: TConsoleColorPair);
begin
  FWarnBadge.Assign(AValue);
end;

procedure TTermColorScheme.SetPromptInput(const AValue: TConsoleColorPair);
begin
  FPromptInput.Assign(AValue);
end;

procedure TTermColorScheme.SetLog(const AValue: TConsoleColorPair);
begin
  FLog.Assign(AValue);
end;

procedure TTermColorScheme.SetMarkdown(const AValue: TMarkdownColorScheme);
begin
  FMarkdown.Assign(AValue);
end;

procedure TTermColorScheme.Assign(Source: TPersistent);
var
  Src: TTermColorScheme;
begin
  if Source is TTermColorScheme then
  begin
    Src := TTermColorScheme(Source);
    FDefaultText := Src.FDefaultText;
    FThinkingText := Src.FThinkingText;
    FWelcomeBadge.Assign(Src.FWelcomeBadge);
    FThinkingBadge.Assign(Src.FThinkingBadge);
    FToolBadge.Assign(Src.FToolBadge);
    FErrorBadge.Assign(Src.FErrorBadge);
    FWarnBadge.Assign(Src.FWarnBadge);
    FPromptInput.Assign(Src.FPromptInput);
    FLog.Assign(Src.FLog);
    FMarkdown.Assign(Src.FMarkdown);
  end
  else
    inherited Assign(Source);
end;

{ TCustomTermManager }

constructor TCustomTermManager.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  // Empty Path means "use process current directory" at runtime
  FPath := '';
  FPrompt := '{path}> ';
  FWelcome := '';
  FThinkingLabel := '[Thinking]';
  FShowThinking := True;
  FToolCallLabel := '[{name}: {command}]';
  FLastCharWasNewLine := True;
  FStripEmoji := True;
  FColorOutput := True;
  FColors := TTermColorScheme.Create;
  FDefaultModelLabel := 'plainconsole';
  FAgent := nil;
  FPendingScreenRow := -1;
  FPendingScreenCol := -1;
  FLastInputScreenCleared := False;
  FCurrentOutputMark := False;
  {$IFDEF WINDOWS}
  FDefaultConsoleAttr := 0;
  FDefaultConsoleAttrCaptured := False;
  {$ENDIF}
  FPrevAgentOnChunk := nil;
  FPrevAgentOnThinking := nil;
  FPrevAgentOnToolCall := nil;
  FPrevAgentOnToolResult := nil;
  FPrevAgentOnFinish := nil;
  FPrevAgentOnExecCommand := nil;
  FPrevAgentOnAskUser := nil;
  FPrevAgentOnContextUsage := nil;
  FInThinking := False;
  FFirstChunkSeen := False;
  FFinishToolCalled := False;
  FWaitSlowHint := 'Waiting for response, the model may be loading weights on the first call, please wait...';
  FWaitServerDownHint := 'Waiting but server appears unreachable, check Ollama address with "set baseurl <url>"';
  FWaitCheckDelayMs := 10000;
  FBuiltinCommands := TStringList.Create;
  FBuiltinCommands.Add('cd');
  FBuiltinCommands.Add('pwd');
  FBuiltinCommands.Add('cls');
  FBuiltinCommands.Add('new');
  FBuiltinCommands.Add('clear');
  FBuiltinCommands.Add('help');
  FBuiltinCommands.Add('h');
  FBuiltinCommands.Add('history');
  FBuiltinCommands.Add('exit');
  FBuiltinCommands.Add('quit');
  FBuiltinCommands.Add('set');
  FBuiltinCommands.Add('get');
  FBuiltinCommands.Add('config');
  FBuiltinCommands.Add('settings');
  FBuiltinCommands.Add('models');
  FBuiltinCommands.Add('term');
  FBuiltinCommands.Add('ollama');
  FOllamaOpDone := True;
  FOllamaOpKind := oekNone;
  FOllamaOpError := '';
  FOllamaWaitModel := '';
  FOllamaPullPct := -1;
  FOllamaPullLastStep := -1;
  FHistory := TStringList.Create;
  FHistoryMax := 200;
  FShellExec := 'cmd.exe';
  FCommandTimeout := 0;
  FMaxCaptureBytes := 65536;
  FAgentCommandTimeout := 30000;
  FUsePrefixes := True;
  FSearchPath := True;
  FShellHistory := TAgentShellHistory.Create;
  FShellLog := TStringList.Create;
  FCapturing := False;
  FCaptureCommand := '';
  FCaptureOutput := '';
  FCaptureError := False;
  FRunning := False;
  FLastExitCode := 0;
end;

destructor TCustomTermManager.Destroy;
begin
  SetAgent(nil);
  FShellHistory.Free;
  FShellLog.Free;
  FColors.Free;
  FHistory.Free;
  FBuiltinCommands.Free;
  inherited Destroy;
end;

// Updates the native terminal window title with the current directory
procedure TCustomTermManager.UpdateConsoleTitle;
var
  Title: string;
begin
  if csDesigning in ComponentState then
    Exit;

  Title := 'PlainConsole - ' + GetPromptText;

  {$IFDEF WINDOWS}
  SetConsoleTitleW(PWideChar(UTF8Decode(Title)));
  {$ELSE}
  Write(#27']0;' + UTF8Encode(Title) + #7);
  Flush(Output);
  {$ENDIF}
end;

procedure TCustomTermManager.SetPath(const AValue: string);
var
  NewPath: string;
begin
  if AValue = '' then
  begin
    FPath := '';
    UpdateConsoleTitle;

    // Keep agent workspace in sync with terminal directory
    if Assigned(FAgent) and not (csDesigning in ComponentState) then
      FAgent.RootPath := GetEffectivePath;
    Exit;
  end;
  NewPath := ExpandFileName(AValue);
  if DirectoryExists(NewPath) then
  begin
    NewPath := ExcludeTrailingPathDelimiter(NewPath);
    {$IFDEF WINDOWS}
    if (Length(NewPath) = 2) and (NewPath[2] = ':') then
      NewPath := NewPath + PathDelim;
    {$ENDIF}
    FPath := NewPath;
    UpdateConsoleTitle;

    // Keep agent workspace in sync with terminal directory
    if Assigned(FAgent) and not (csDesigning in ComponentState) then
      FAgent.RootPath := GetEffectivePath;
  end;
end;

procedure TCustomTermManager.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);

  // Clear references when the agent is being destroyed
  if (Operation = opRemove) and (AComponent = FAgent) then
  begin
    FAgent := nil;
    FPrevAgentOnChunk := nil;
    FPrevAgentOnThinking := nil;
    FPrevAgentOnToolCall := nil;
    FPrevAgentOnToolResult := nil;
    FPrevAgentOnFinish := nil;
    FPrevAgentOnExecCommand := nil;
    FPrevAgentOnAskUser := nil;
    FPrevAgentOnContextUsage := nil;
    FPrevAgentOnLog := nil;
    FInThinking := False;
  end;
end;

procedure TCustomTermManager.SetAgent(const AValue: TCustomOllamaAgent);
begin
  if FAgent = AValue then
    Exit;

  // Preserve the current chat buffers before detaching the agent
  if Assigned(FAgent) and Assigned(FAgent.ActiveChat) then
  begin
    FAgent.ActiveChat.TerminalHistory.Assign(FHistory);
    FAgent.ActiveChat.ShellLog.Assign(FShellLog);
  end;

  if Assigned(FAgent) then
    FAgent.RemoveFreeNotification(Self);

  FAgent := AValue;
  FPrevAgentOnChunk := nil;
  FPrevAgentOnThinking := nil;
  FPrevAgentOnToolCall := nil;
  FPrevAgentOnToolResult := nil;
  FPrevAgentOnFinish := nil;
  FPrevAgentOnExecCommand := nil;
  FPrevAgentOnAskUser := nil;
  FPrevAgentOnLog := nil;
  FInThinking := False;

  if Assigned(FAgent) then
  begin
    FAgent.FreeNotification(Self);

    if Assigned(FAgent.ActiveChat) then
    begin
      FHistory.Assign(FAgent.ActiveChat.TerminalHistory);
      RestoreTerminalHistory;
      FShellLog.Assign(FAgent.ActiveChat.ShellLog);
    end;

    // Share terminal directory and shell name with the agent at runtime only
    if not (csDesigning in ComponentState) then
    begin
      FAgent.RootPath := GetEffectivePath;
      FAgent.ExecShellInfo := FShellExec;
      // Route agent log lines through the terminal so they are colored
      FPrevAgentOnLog := FAgent.OnLog;
      FAgent.OnLog := @HandleAgentLog;
    end;
  end;
end;

function TCustomTermManager.SwitchActiveChat(ADelta: integer): boolean;
begin
  Result := False;
  if not Assigned(FAgent) or not Assigned(FAgent.ActiveChat) then
    Exit;

  if not FAgent.SwitchChat(ADelta) then
    Exit;

  // Keep terminal directory in sync with the active chat working directory
  if Assigned(FAgent.ActiveChat) and (FAgent.ActiveChat.WorkingDirectory <> '') and
    DirectoryExists(FAgent.ActiveChat.WorkingDirectory) then
    Path := FAgent.ActiveChat.WorkingDirectory;

  RestoreActiveChat;
  Result := True;
end;

function TCustomTermManager.MoveActiveChat(ADelta: integer): boolean;
begin
  Result := False;
  if not Assigned(FAgent) or not Assigned(FAgent.ActiveChat) then
    Exit;

  Result := FAgent.MoveActiveChat(ADelta);

  if Result then
    UpdateConsoleTitle;
end;

procedure TCustomTermManager.AppendChatOutput(const AText: string);
begin
  if AText = string.Empty then
    Exit;
  if FRestoringChat or FSuppressChatOutput then
    Exit;
  if not Assigned(FAgent) or not Assigned(FAgent.ActiveChat) then
    Exit;

  FAgent.ActiveChat.MarkSessionActive;
  FAgent.ActiveChat.TerminalOutput :=
    FAgent.ActiveChat.TerminalOutput + AText;
end;

procedure TCustomTermManager.SetHistory(const AValue: TStringList);
begin
  if not Assigned(AValue) or (AValue = FHistory) then
  begin
    // Assigning nil clears the buffer, self-assignment is a no-op
    if not Assigned(AValue) then
      FHistory.Clear;
    Exit;
  end;
  FHistory.Assign(AValue);
end;

procedure TCustomTermManager.SetColors(const AValue: TTermColorScheme);
begin
  if Assigned(AValue) and (AValue <> FColors) then
    FColors.Assign(AValue);
end;

procedure TCustomTermManager.SetShellHistory(const AValue: TAgentShellHistory);
begin
  if Assigned(AValue) and (AValue <> FShellHistory) then
    FShellHistory.Assign(AValue);
end;

procedure TCustomTermManager.ProcessMarkdownChunk(const AText: string; AFinal: boolean);
var
  P: SizeInt;
  Line: string;
begin
  FMarkdownPending := FMarkdownPending + AText;

  while True do
  begin
    P := Pos(#10, FMarkdownPending);
    if P = 0 then
      Break;

    Line := Copy(FMarkdownPending, 1, P);
    Delete(FMarkdownPending, 1, P);
    ProcessMarkdownLine(Line);
  end;

  if AFinal and (FMarkdownPending <> string.Empty) then
  begin
    ProcessMarkdownLine(FMarkdownPending);
    FMarkdownPending := string.Empty;
  end;
end;

procedure TCustomTermManager.ProcessMarkdownLine(const ALine: string);
const
  MARKERS: array[0..4] of string = ('**', '__', '~~', '==', '*');
  MARKER_COLORS: array[0..4] of TTermColor = (
    tcMarkdownBold, tcMarkdownBold, tcMarkdownStrike,
    tcMarkdownHighlight, tcMarkdownItalic);
var
  Line, LineEndingText, Content: string;
  I, J, PrefixStart, ContentStart: SizeInt;
  FenceChar: char;
  BaseColor: TTermColor;

  procedure OutputText(const AText: string; AColor: TTermColor);
  begin
    if AText = string.Empty then
      Exit;

    SetColor(AColor);
    WriteText(AText, False);
  end;

  function IsEscapedAt(const AText: string; APos: SizeInt): boolean;
  var
    P, Count: SizeInt;
  begin
    Count := 0;
    P := APos - 1;

    while (P > 0) and (AText[P] = '\') do
    begin
      Inc(Count);
      Dec(P);
    end;

    Result := (Count mod 2) = 1;
  end;

  function IsMarkdownEscapable(AChar: char): boolean;
  begin
    Result := AChar in ['\', '`', '*', '_', '~', '='];
  end;

  function FindClosingCodeMarker(const AText: string; AStart, ALength: SizeInt): SizeInt;
  var
    P, RunLength: SizeInt;
  begin
    Result := 0;
    P := AStart;

    while P <= Length(AText) do
    begin
      if AText[P] = '`' then
      begin
        RunLength := 1;
        while (P + RunLength <= Length(AText)) and (AText[P + RunLength] = '`') do
          Inc(RunLength);

        if (RunLength = ALength) and not IsEscapedAt(AText, P) then
        begin
          Result := P;
          Exit;
        end;

        Inc(P, RunLength);
      end
      else
        Inc(P);
    end;
  end;

  function FindClosingMarker(const AText, AMarker: string; AStart: SizeInt): SizeInt;
  var
    P, RunLength, CodeClose: SizeInt;
  begin
    Result := 0;
    P := AStart;

    while P <= Length(AText) - Length(AMarker) + 1 do
    begin
      // Skip escaped Markdown characters
      if (AText[P] = '\') and (P < Length(AText)) and IsMarkdownEscapable(AText[P + 1]) then
      begin
        Inc(P, 2);
        Continue;
      end;

      // Inline code has priority over other Markdown delimiters
      if AText[P] = '`' then
      begin
        RunLength := 1;
        while (P + RunLength <= Length(AText)) and (AText[P + RunLength] = '`') do
          Inc(RunLength);

        CodeClose := FindClosingCodeMarker(AText, P + RunLength, RunLength);

        if CodeClose = 0 then
          Exit;

        P := CodeClose + RunLength;
        Continue;
      end;

      if (Copy(AText, P, Length(AMarker)) = AMarker) and not IsEscapedAt(AText, P) then
      begin
        Result := P;
        Exit;
      end;

      Inc(P);
    end;
  end;

  procedure ProcessInlineText(const AText: string; AColor: TTermColor);
  var
    P, Q, RunLength, CodeClose, MarkerPos, LocalMarkerIndex: SizeInt;
    CurrentDelimiter: string;
  begin
    P := 1;

    while P <= Length(AText) do
    begin
      // Preserve escaped Markdown characters as plain text
      if (AText[P] = '\') and (P < Length(AText)) and IsMarkdownEscapable(AText[P + 1]) then
      begin
        OutputText(Copy(AText, P, 2), AColor);
        Inc(P, 2);
        Continue;
      end;

      // Process inline code before all other Markdown markers
      if AText[P] = '`' then
      begin
        RunLength := 1;
        while (P + RunLength <= Length(AText)) and (AText[P + RunLength] = '`') do
          Inc(RunLength);

        CodeClose := FindClosingCodeMarker(AText, P + RunLength, RunLength);

        if CodeClose > 0 then
        begin
          OutputText(Copy(AText, P, RunLength), tcMarkdownMarker);
          OutputText(Copy(AText, P + RunLength, CodeClose - P - RunLength), tcMarkdownCode);
          OutputText(Copy(AText, CodeClose, RunLength), tcMarkdownMarker);
          P := CodeClose + RunLength;
          Continue;
        end;

        OutputText(Copy(AText, P, RunLength), AColor);
        Inc(P, RunLength);
        Continue;
      end;

      LocalMarkerIndex := -1;
      CurrentDelimiter := string.Empty;

      for Q := Low(MARKERS) to High(MARKERS) do
      begin
        if (Copy(AText, P, Length(MARKERS[Q])) = MARKERS[Q]) and not IsEscapedAt(AText, P) then
        begin
          LocalMarkerIndex := Q;
          CurrentDelimiter := MARKERS[Q];
          Break;
        end;
      end;

      if LocalMarkerIndex >= 0 then
      begin
        MarkerPos := FindClosingMarker(AText, CurrentDelimiter, P + Length(CurrentDelimiter));

        if MarkerPos > 0 then
        begin
          OutputText(CurrentDelimiter, tcMarkdownMarker);
          Content := Copy(AText, P + Length(CurrentDelimiter), MarkerPos - P - Length(CurrentDelimiter));
          OutputText(Content, MARKER_COLORS[LocalMarkerIndex]);
          OutputText(CurrentDelimiter, tcMarkdownMarker);

          P := MarkerPos + Length(CurrentDelimiter);
          Continue;
        end;
      end;

      // Output regular text until the next possible Markdown marker
      Q := P + 1;
      while Q <= Length(AText) do
      begin
        if (AText[Q] = '`') or ((AText[Q] = '\') and (Q < Length(AText)) and IsMarkdownEscapable(AText[Q + 1])) or
          ((Copy(AText, Q, 2) = '**') or (Copy(AText, Q, 2) = '__') or (Copy(AText, Q, 2) = '~~') or
          (Copy(AText, Q, 2) = '==')) or (AText[Q] = '*') then
          Break;

        Inc(Q);
      end;

      OutputText(Copy(AText, P, Q - P), AColor);
      P := Q;
    end;
  end;

begin
  Line := ALine;
  LineEndingText := string.Empty;

  // Keep the original line ending unchanged
  if (Length(Line) > 0) and (Line[Length(Line)] = #10) then
  begin
    LineEndingText := #10;
    Delete(Line, Length(Line), 1);

    if (Length(Line) > 0) and (Line[Length(Line)] = #13) then
    begin
      LineEndingText := #13#10;
      Delete(Line, Length(Line), 1);
    end;
  end;

  // Detect fenced code blocks
  I := 1;
  while (I <= Length(Line)) and (Line[I] = ' ') do
    Inc(I);

  if (I <= Length(Line) - 2) and ((Copy(Line, I, 3) = '```') or (Copy(Line, I, 3) = '~~~')) then
  begin
    FenceChar := Line[I];

    if not FMarkdownFencedCode then
    begin
      FMarkdownFencedCode := True;
      FMarkdownFenceChar := FenceChar;
    end
    else if FMarkdownFenceChar = FenceChar then
      FMarkdownFencedCode := False;

    OutputText(Copy(Line, 1, I - 1), tcDefault);
    OutputText(Copy(Line, I, 3), tcMarkdownMarker);
    OutputText(Copy(Line, I + 3, MaxInt), tcDefault);
    OutputText(LineEndingText, tcDefault);
    SetColor(tcDefault);
    Exit;
  end;

  if FMarkdownFencedCode then
  begin
    OutputText(Line + LineEndingText, tcMarkdownFencedCode);
    SetColor(tcDefault);
    Exit;
  end;

  // Detect Markdown line prefixes
  PrefixStart := 1;
  while (PrefixStart <= Length(Line)) and (Line[PrefixStart] = ' ') do
    Inc(PrefixStart);

  ContentStart := PrefixStart;
  BaseColor := tcDefault;

  // Detect headings
  J := PrefixStart;
  while (J <= Length(Line)) and (Line[J] = '#') do
    Inc(J);

  if (J > PrefixStart) and (J <= Length(Line)) and (Line[J] = ' ') and (J - PrefixStart <= 6) then
  begin
    BaseColor := tcMarkdownHeading;

    OutputText(Copy(Line, 1, PrefixStart - 1), tcDefault);
    OutputText(Copy(Line, PrefixStart, J - PrefixStart), tcMarkdownMarker);
    ContentStart := J + 1;
  end
  else if (PrefixStart <= Length(Line)) and (Line[PrefixStart] = '>') then
  begin
    BaseColor := tcMarkdownQuote;

    OutputText(Copy(Line, 1, PrefixStart - 1), tcDefault);
    OutputText('>', tcMarkdownMarker);
    ContentStart := PrefixStart + 1;

    if (ContentStart <= Length(Line)) and (Line[ContentStart] = ' ') then
      Inc(ContentStart);
  end
  else
  begin
    // Detect unordered lists
    if (PrefixStart <= Length(Line)) and (Line[PrefixStart] in ['-', '+', '*']) and (PrefixStart < Length(Line)) and
      (Line[PrefixStart + 1] = ' ') then
    begin
      OutputText(Copy(Line, 1, PrefixStart - 1), tcDefault);
      OutputText(Line[PrefixStart], tcMarkdownMarker);
      ContentStart := PrefixStart + 2;
    end
    else
    begin
      // Detect ordered lists, including nested numbering such as 1.1.
      J := PrefixStart;
      while (J <= Length(Line)) and (Line[J] in ['0'..'9', '.']) do
        Inc(J);

      if (J > PrefixStart) and (J <= Length(Line)) and (Line[J] = ' ') and (Line[J - 1] = '.') then
      begin
        OutputText(Copy(Line, 1, PrefixStart - 1), tcDefault);
        OutputText(Copy(Line, PrefixStart, J - PrefixStart), tcMarkdownMarker);
        ContentStart := J + 1;
      end;
    end;
  end;

  // Parse the remaining text even when the line has a Markdown prefix
  ProcessInlineText(Copy(Line, ContentStart, MaxInt), BaseColor);

  OutputText(LineEndingText, tcDefault);
  SetColor(tcDefault);
end;

procedure TCustomTermManager.HandleAgentChunk(Sender: TObject; const AText: string);
begin
  FFirstChunkSeen := True;
  // Close thinking block if open, this also resets color
  CloseThinking;
  ProcessMarkdownChunk(AText);
  if Assigned(FPrevAgentOnChunk) then
    FPrevAgentOnChunk(Sender, AText);
end;

procedure TCustomTermManager.CloseThinking;
begin
  if FInThinking then
  begin
    SetColor(tcDefault);
    // Close the last thinking line if it was not terminated
    if not FLastCharWasNewLine then
      WriteLine('', True);
    // Emit blank line for visual separation from the next block
    WriteLine('', True);
    FInThinking := False;
  end;
  // Always reset color, even if no thinking block was open
  SetColor(tcDefault);
end;

procedure TCustomTermManager.HandleAgentThinking(Sender: TObject; const AText: string);
begin
  FFirstChunkSeen := True;
  // Emit label and newline once at the beginning of a thinking block
  if not FInThinking then
  begin
    SetColor(tcThinkingBadge);
    WriteText(FThinkingLabel, True);
    SetColor(tcDefault);
    WriteLine('', True);
    // Switch to thinking text color for the reasoning body
    SetColor(tcDim);
    FInThinking := True;
  end;
  // Show thinking text only when enabled, otherwise just the label
  if FShowThinking then
    WriteText(AText, True);
  if Assigned(FPrevAgentOnThinking) then
    FPrevAgentOnThinking(Sender, AText);
end;

procedure TCustomTermManager.HandleAgentToolCall(Sender: TObject; const AName, AArgsJson: string);
var
  LabelText, Key: string;
  Data: TJSONData;
  Obj: TJSONObject;
  P, KeyStart, KeyEnd: integer;
begin
  // Any tool call means the agent has started working
  FFirstChunkSeen := True;
  CloseThinking;

  if AName = 'finish' then
  begin
    FFinishToolCalled := True;
    // finish only signals completion, the answer was already streamed
    if not FLastCharWasNewLine then
      WriteLine('', True);
    SetColor(tcToolBadge);
    WriteText('[finish]', True);
    SetColor(tcDefault);
    WriteLine('', True);
    if Assigned(FPrevAgentOnToolCall) then
      FPrevAgentOnToolCall(Sender, AName, AArgsJson);
    Exit;
  end;

  LabelText := FToolCallLabel;
  // Substitute {name} and {args} first
  LabelText := StringReplace(LabelText, '{name}', AName, [rfReplaceAll]);
  LabelText := StringReplace(LabelText, '{args}', AArgsJson, [rfReplaceAll]);
  // Replace remaining {key} with corresponding JSON field value when present
  Data := nil;
  try
    try
      Data := GetJSON(AArgsJson);
    except
      Data := nil;
    end;
    if (Data <> nil) and (Data.JSONType = jtObject) then
    begin
      Obj := TJSONObject(Data);
      P := 1;
      while P <= Length(LabelText) do
      begin
        KeyStart := Pos('{', LabelText, P);
        if KeyStart = 0 then
          Break;
        KeyEnd := Pos('}', LabelText, KeyStart);
        if KeyEnd = 0 then
          Break;
        Key := Copy(LabelText, KeyStart + 1, KeyEnd - KeyStart - 1);
        if Obj.Find(Key) <> nil then
          LabelText := Copy(LabelText, 1, KeyStart - 1) + Obj.Find(Key).AsString + Copy(LabelText, KeyEnd + 1, MaxInt)
        else
          P := KeyEnd + 1;
      end;
    end;
  finally
    Data.Free;
  end;
  // Close the current line if it was not terminated
  if not FLastCharWasNewLine then
    WriteLine('', True);
  SetColor(tcToolBadge);
  WriteText(LabelText, True);
  SetColor(tcDefault);
  WriteLine('', True);
  // No blank line here, the tool result preview follows immediately
  if Assigned(FPrevAgentOnToolCall) then
    FPrevAgentOnToolCall(Sender, AName, AArgsJson);
end;

procedure TCustomTermManager.HandleAgentToolResult(Sender: TObject; const AName, AResult: string);
begin
  // Preview is emitted by the agent through OnLog, only forward here
  if Assigned(FPrevAgentOnToolResult) then
    FPrevAgentOnToolResult(Sender, AName, AResult);
end;

procedure TCustomTermManager.HandleAgentLog(Sender: TObject; const AText: string);
begin
  // Close any open thinking block so the log starts on a fresh line
  CloseThinking;
  if not FLastCharWasNewLine then
    WriteLine('', True);

  SetColor(tcLog);
  try
    WriteText(AText, True);
  finally
    SetColor(tcDefault);
  end;

  WriteLine('', True);
end;

procedure TCustomTermManager.HandleAgentContextUsage(Sender: TObject; AUsed, ATotal: integer);
begin
  // Refresh the native title using the current agent counters
  UpdateConsoleTitle;

  if Assigned(FPrevAgentOnContextUsage) then
    FPrevAgentOnContextUsage(Sender, AUsed, ATotal);
end;

procedure TCustomTermManager.HandleAgentFinish(Sender: TObject; AReason: TAgentFinishReason; const AAnswer, AErrorMsg: string);
var
  Streamed: boolean;
begin
  ProcessMarkdownChunk(string.Empty, True);
  CloseThinking;
  // Guarantee default color even if CloseThinking was bypassed
  SetColor(tcDefault);
  Streamed := Assigned(FAgent) and FAgent.Streaming;
  case AReason of
    afrSuccess:
    begin
      // Signal empty response so the user is not left with silence
      if AAnswer = '' then
      begin
        SetColor(tcWarnBadge);
        WriteText('[empty response from model]', True);
        SetColor(tcDefault);
        WriteLine('', True);
      end
      else if not Streamed then
        WriteLine(AAnswer, False)
      else if not FLastCharWasNewLine then
        WriteLine('', False);
    end;
    afrCancelled:
      WriteLine('^C', True);
    afrMaxSteps:
    begin
      SetColor(tcWarnBadge);
      WriteText('[max steps reached]', True);
      SetColor(tcDefault);
      WriteLine('', True);
    end;
    afrError:
    begin
      SetColor(tcErrorBadge);
      WriteText('[error: ' + AErrorMsg + ']', True);
      SetColor(tcDefault);
      WriteLine('', True);
    end;
    afrModelNotSet:
    begin
      SetColor(tcErrorBadge);
      WriteText('[agent not configured: ' + AErrorMsg + ']', True);
      SetColor(tcDefault);
      WriteLine('', True);
    end;
    else
      ;
  end;
  // Blank line after any finish for visual separation from the next prompt
  WriteLine('', False);
  FFinishToolCalled := False;
  if Assigned(FPrevAgentOnFinish) then
    FPrevAgentOnFinish(Sender, AReason, AAnswer, AErrorMsg);
end;

procedure TCustomTermManager.RecordShellOperation(const ACommand, AOutput: string; AIsError: boolean);
var
  Truncated, Line: string;
begin
  if not FShellHistory.Enabled then
    Exit;
  if Trim(ACommand) = '' then
    Exit;
  Truncated := AOutput;
  if Length(Truncated) > FShellHistory.MaxOutputBytes then
    Truncated := Copy(Truncated, 1, FShellHistory.MaxOutputBytes) + #10 + '[output truncated at ' +
      IntToStr(FShellHistory.MaxOutputBytes) + ' bytes]';
  if AIsError then
    Line := 'E' + #1 + ACommand + #1 + Truncated
  else
    Line := 'C' + #1 + ACommand + #1 + Truncated;
  FShellLog.Add(Line);
  while FShellLog.Count > FShellHistory.MaxEntries do
    FShellLog.Delete(0);

  if Assigned(FAgent) and Assigned(FAgent.ActiveChat) then
  begin
    if FCurrentOutputMark then
      FAgent.ActiveChat.IncrementLastOutputMarkShellLogCount;

    FAgent.ActiveChat.ShellLog.Assign(FShellLog);
    FAgent.ActiveChat.MarkSessionActive;
  end;
end;

function TCustomTermManager.IsMetaCommand(const ACommand: string): boolean;
var
  Cmd, SubCmd: string;
  P: integer;
begin
  P := Pos(' ', ACommand);
  if P > 0 then
  begin
    Cmd := LowerCase(Copy(ACommand, 1, P - 1));
    SubCmd := LowerCase(Trim(Copy(ACommand, P + 1, MaxInt)));
  end
  else
  begin
    Cmd := LowerCase(ACommand);
    SubCmd := string.Empty;
  end;

  Result := (Cmd = 'cls') or (Cmd = 'clear') or (Cmd = 'new') or (Cmd = 'exit') or (Cmd = 'quit') or
    (Cmd = 'help') or (Cmd = 'h') or (Cmd = '?') or (Cmd = 'config') or (Cmd = 'settings') or (Cmd = 'get') or
    (Cmd = 'history') or ((Cmd = 'set') and ((SubCmd = 'chat') or (SubCmd = 'chatprompt')));
end;

function TCustomTermManager.IsChatControlCommand(const ACommand: string): boolean;
var
  Cmd: string;
  P: integer;
begin
  P := Pos(' ', Trim(ACommand));
  if P > 0 then
    Cmd := LowerCase(Copy(Trim(ACommand), 1, P - 1))
  else
    Cmd := LowerCase(Trim(ACommand));

  Result := (Cmd = 'cls') or (Cmd = 'clear') or (Cmd = 'new') or (Cmd = 'exit') or (Cmd = 'quit');
end;

function TCustomTermManager.BuildShellContext: string;
var
  Buf: TStringList;
  I, P: integer;
  Line, Rest, Cmd, OutText: string;
  IsErr, HasErr: boolean;
begin
  Result := '';
  if not FShellHistory.Enabled or (FShellLog.Count = 0) then
    Exit;
  Buf := TStringList.Create;
  try
    Buf.Add('Recent shell activity in the workspace:');
    Buf.Add('');
    HasErr := False;
    for I := 0 to FShellLog.Count - 1 do
    begin
      Line := FShellLog[I];
      if Length(Line) < 3 then
        Continue;
      IsErr := Line[1] = 'E';
      if IsErr then
        HasErr := True;
      Rest := Copy(Line, 3, MaxInt);
      P := Pos(#1, Rest);
      if P = 0 then
        Continue;
      Cmd := Copy(Rest, 1, P - 1);
      OutText := Copy(Rest, P + 1, MaxInt);
      Buf.Add('$ ' + Cmd);
      while (Length(OutText) > 0) and (OutText[Length(OutText)] in [#10, #13]) do
        Delete(OutText, Length(OutText), 1);
      if OutText <> '' then
        Buf.Add(OutText);
      Buf.Add('');
    end;
    if HasErr then
      Buf.Add('(some of the commands above produced error output)');
    Result := Buf.Text;
  finally
    Buf.Free;
  end;
end;

procedure TCustomTermManager.HandleAgentExecCommand(Sender: TObject; const ACommand: string; var AResult: string; var AAllow: boolean);
const
  // Unix utilities that cmd.exe does not have
  UNIX_CMDS: array[0..15] of string = (
    'ls', 'cat', 'grep', 'head', 'tail', 'rm', 'cp', 'mv',
    'touch', 'which', 'chmod', 'chown', 'sudo', 'sed', 'awk', 'wc');
  // Windows utilities that Unix shells do not have
  WIN_CMDS: array[0..3] of string = (
    'findstr', 'cls', 'where', 'powershell');

// True when AName appears as a command token, not as an argument or path
  function IsCommandToken(const ACommand, AName: string): boolean;
  var
    Padded: string;
  begin
    Padded := ' ' + LowerCase(ACommand) + ' ';
    Result := (Pos(' ' + AName + ' ', Padded) = 1) or (Pos('| ' + AName + ' ', Padded) > 0) or
      (Pos('&& ' + AName + ' ', Padded) > 0) or (Pos('; ' + AName + ' ', Padded) > 0);
  end;

  // True when the command starts with a listing or search utility
  function IsListingOrSearchCommand(const ALowCmd: string): boolean;
  const
    CMDS: array[0..14] of string = (
      'dir', 'ls', 'type', 'cat', 'find', 'findstr', 'grep', 'where', 'which',
      'tree', 'head', 'tail', 'more', 'rg', 'fd');
  var
    I: integer;
  begin
    Result := False;
    for I := Low(CMDS) to High(CMDS) do
      if (ALowCmd = CMDS[I]) or ((Length(ALowCmd) > Length(CMDS[I])) and (Copy(ALowCmd, 1, Length(CMDS[I]) + 1) =
        CMDS[I] + ' ')) then
        Exit(True);
  end;

var
  ExitCode, I: integer;
  Hint, FoundCmd, LowCmd: string;
  Family: TShellFamily;
  InQuote: boolean;
begin
  // When host provided own handler, let it run and skip default execution
  if Assigned(FPrevAgentOnExecCommand) then
  begin
    FPrevAgentOnExecCommand(Sender, ACommand, AResult, AAllow);
    Exit;
  end;
  AAllow := True;
  ExitCode := 0;
  AResult := ExecuteCommandCapture(ACommand, ExitCode, FAgentCommandTimeout);

  Hint := '';
  Family := DetectShellFamily(FShellExec);

  // Shell-specific command family mismatches
  case Family of
    sfCmd:
    begin
      for I := Low(UNIX_CMDS) to High(UNIX_CMDS) do
        if IsCommandToken(ACommand, UNIX_CMDS[I]) then
        begin
          FoundCmd := UNIX_CMDS[I];
          Hint := 'Note: this shell is cmd.exe, not Unix. "' + FoundCmd + '" is not available. ' +
            'Use dir instead of ls, type instead of cat, findstr instead of grep, and remove | head / | tail.';
          Break;
        end;
      // Semicolons are not command separators in cmd.exe
      if Hint = '' then
      begin
        InQuote := False;
        for I := 1 to Length(ACommand) do
        begin
          if ACommand[I] = '"' then
            InQuote := not InQuote
          else if (ACommand[I] = ';') and not InQuote then
          begin
            Hint := 'Note: cmd.exe does not use ";" to chain commands, it is treated as a literal. ' +
              'Use "&&" to chain, or run one command per call.';
            Break;
          end;
        end;
      end;
      // findstr treats $ and \. literally, not as regex anchors
      if (Hint = '') and (Pos('findstr', LowerCase(ACommand)) > 0) and ((Pos('$', ACommand) > 0) or (Pos('\.', ACommand) > 0)) then
        Hint := 'Note: findstr uses limited Windows regex, "$" and "\." are literal characters. ' +
          'Use the grep tool for text search, it is more reliable.';
      // Unix find syntax, cmd.exe find only searches text inside files
      if (Hint = '') and (Pos(' find ', ' ' + LowerCase(ACommand) + ' ') > 0) and
        ((Pos(' -type ', ' ' + LowerCase(ACommand) + ' ') > 0) or (Pos(' -name ', ' ' + LowerCase(ACommand) + ' ') > 0) or
        (Pos(' -maxdepth ', ' ' + LowerCase(ACommand) + ' ') > 0) or (Pos(' -not ', ' ' + LowerCase(ACommand) + ' ') > 0)) then
        Hint := 'Note: "find" in cmd.exe searches text inside files, not filenames, ' +
          'and does not accept Unix options like -type, -name, -maxdepth. ' +
          'Use find_files tool with a glob pattern for filename search, or grep tool for text search.';
      // dir /s produces huge output on large trees, prefer file tools
      if (Hint = '') and (Pos('dir ', ' ' + LowerCase(ACommand) + ' ') > 0) and
        (Pos(' /s', ' ' + LowerCase(ACommand) + ' ') > 0) then
        Hint := 'Note: "dir /s" recurses into all subdirectories, it can take a long time ' +
          'and produce huge output on large projects. Use find_files with a glob pattern ' +
          'or list_files on a specific subdirectory instead.';
    end;
    sfUnix:
    begin
      for I := Low(WIN_CMDS) to High(WIN_CMDS) do
        if IsCommandToken(ACommand, WIN_CMDS[I]) then
        begin
          FoundCmd := WIN_CMDS[I];
          Hint := 'Note: this shell is ' + ExtractFileName(FShellExec) + ', not cmd.exe. "' + FoundCmd +
            '" is not available on Unix. Use ls instead of dir, cat instead of type, grep instead of findstr.';
          Break;
        end;
    end;
    else
      ; // PowerShell aliases overlap both worlds, no hint to avoid false positives
  end;

  // Universal rule: redirecting listing/search output to files pollutes the workspace
  if (Hint = '') and (Pos(' > ', ' ' + ACommand + ' ') > 0) then
  begin
    LowCmd := LowerCase(TrimLeft(ACommand));
    if IsListingOrSearchCommand(LowCmd) then
      Hint := 'Note: do not redirect listing or search output to a file, use list_files, find_files ' +
        'or grep tools instead. Those return results directly and do not pollute the workspace.';
  end;

  // Make empty output distinguishable from a silent success
  if Trim(AResult) = '' then
    AResult := '(command produced no output, exit code ' + IntToStr(ExitCode) + ')';

  if Hint <> '' then
    AResult := AResult + #10 + Hint;
end;

procedure TCustomTermManager.HandleAgentAskUser(Sender: TObject; const AQuestion: string; var AAnswer: string; var AAllow: boolean);
begin
  // When host provided own handler, let it run and skip interactive prompt
  if Assigned(FPrevAgentOnAskUser) then
  begin
    FPrevAgentOnAskUser(Sender, AQuestion, AAnswer, AAllow);
    Exit;
  end;
  AAllow := True;
  AAnswer := '';
  // Close any open thinking or content lines before prompting
  CloseThinking;
  if not FLastCharWasNewLine then
    WriteLine('', False);
  // Badge for the label, question text stays in default color
  SetColor(tcToolBadge);
  WriteText('[agent asks]', True);
  SetColor(tcDefault);
  WriteLine(' ' + AQuestion, True);
  WriteText(GetPromptText, False);
  AAnswer := ReadLine;
end;

procedure TCustomTermManager.WriteText(const AText: string; AIsStderr: boolean);
var
  Utf8: rawbytestring;
  Sanitized: string;
begin
  if AText = '' then
    Exit;
  try
    if FStripEmoji then
      Sanitized := StripEmojiChars(AText)
    else
      Sanitized := AText;
  except
    // Strip may fail on malformed UTF-8, fall back to raw text
    Sanitized := AText;
  end;

  Sanitized := Sanitized.NormalizeTerminalText;

  AppendChatOutput(Sanitized);
  Utf8 := UTF8Encode(Sanitized);
  {$IFDEF WINDOWS}
  try
    if AIsStderr then
      WriteUtf8ToHandle(GetStdHandle(STD_ERROR_HANDLE), Utf8)
    else
      WriteUtf8ToHandle(GetStdHandle(STD_OUTPUT_HANDLE), Utf8);
  except
    ; // Console may be detached, keep the agent loop alive
  end;
  {$ELSE}
  try
    if AIsStderr then
    begin
      Write(ErrOutput, AText);
      Flush(ErrOutput);
    end
    else
    begin
      Write(Output, AText);
      Flush(Output);
    end;
  except
    ; // Output stream may be closed, keep the agent loop alive
  end;
  {$ENDIF}
  FLastCharWasNewLine := AText[Length(AText)] in [#10, #13];
  if Assigned(FOnOutput) and not FRestoringChat then
  try
    FOnOutput(Self, AText, AIsStderr);
  except
    ; // Host handler must not break the agent loop
  end;
end;

procedure TCustomTermManager.WriteLine(const AText: string; AIsStderr: boolean);
begin
  WriteText(AText + LineEnding, AIsStderr);
  FLastCharWasNewLine := True;
end;

function TCustomTermManager.GetEffectivePath: string;
begin
  if FPath <> '' then
    Result := FPath
  else
    Result := ExcludeTrailingPathDelimiter(GetCurrentDir);
  // Keep drive root as C:\ instead of C: like cmd.exe
  {$IFDEF WINDOWS}
  if (Length(Result) = 2) and (Result[2] = ':') then
    Result := Result + PathDelim;
  {$ENDIF}
end;

function TCustomTermManager.GetPromptText: string;
var
  ModelName, DefaultLabel, CtxUsed, CtxTotal, CtxPercent, Ctx, CtxKb, CtxUsedKb, CtxTotalKb: string;
  InfoLabel, InfoCtx, ChatName, ChatIndex: string;
  HasContext: boolean;
  I, ChatPosition, ChatCount: integer;
begin
  Result := FPrompt;
  DefaultLabel := string(FDefaultModelLabel);
  if DefaultLabel = '' then
    DefaultLabel := 'plainconsole';

  if Assigned(FAgent) then
  begin
    // Model name, empty when not selected
    ModelName := FAgent.ModelName;
    // Context detection: total > 0 means we know the real window size
    HasContext := FAgent.ContextTotal > 0;
    // Individual placeholders always return numeric values, 0 when unknown
    CtxUsed := IntToStr(FAgent.ContextUsed);
    CtxTotal := IntToStr(FAgent.ContextTotal);
    CtxPercent := IntToStr(FAgent.ContextPercent);
    Ctx := CtxUsed + '/' + CtxTotal;
    CtxUsedKb := IntToStr(FAgent.ContextUsedKb);
    CtxTotalKb := IntToStr(FAgent.ContextTotalKb);
    CtxKb := CtxUsedKb + '/' + CtxTotalKb + 'K';
  end
  else
  begin
    // No agent attached, all values default to 0
    ModelName := '';
    HasContext := False;
    CtxUsed := '0';
    CtxTotal := '0';
    CtxPercent := '0';
    Ctx := '0';
    CtxUsedKb := '0';
    CtxTotalKb := '0';
    CtxKb := '0';
  end;

  // Combined info badge: [model: ctx] when context is known, [plainconsole] otherwise
  if ModelName <> '' then
    InfoLabel := ModelName
  else
    InfoLabel := DefaultLabel;
  if HasContext then
    InfoCtx := ': ' + CtxKb + ' ' + CtxPercent + '%'
  else
    InfoCtx := '';
  Result := StringReplace(Result, '{info}', InfoLabel + InfoCtx, [rfReplaceAll]);

  // Individual placeholders for custom templates
  Result := StringReplace(Result, '{model}', ModelName, [rfReplaceAll]);
  Result := StringReplace(Result, '{default}', DefaultLabel, [rfReplaceAll]);
  Result := StringReplace(Result, '{context_used}', CtxUsed, [rfReplaceAll]);
  Result := StringReplace(Result, '{context_total}', CtxTotal, [rfReplaceAll]);
  Result := StringReplace(Result, '{context_percent}', CtxPercent, [rfReplaceAll]);
  Result := StringReplace(Result, '{context}', Ctx, [rfReplaceAll]);
  Result := StringReplace(Result, '{context_used_kb}', CtxUsedKb, [rfReplaceAll]);
  Result := StringReplace(Result, '{context_total_kb}', CtxTotalKb, [rfReplaceAll]);
  Result := StringReplace(Result, '{context_kb}', CtxKb, [rfReplaceAll]);
  Result := StringReplace(Result, '{path}', GetEffectivePath, [rfReplaceAll]);

  ChatName := string.Empty;
  ChatIndex := '0/0';

  if Assigned(FAgent) and Assigned(FAgent.ActiveChat) then
  begin
    ChatName := FAgent.ActiveChat.Name;
    ChatCount := FAgent.ChatCount;
    ChatPosition := 0;

    for I := 0 to ChatCount - 1 do
      if FAgent.Chats[I] = FAgent.ActiveChat then
      begin
        ChatPosition := I + 1;
        Break;
      end;

    if ChatPosition > 0 then
      ChatIndex := IntToStr(ChatPosition) + '/' + IntToStr(ChatCount);
  end;

  Result := StringReplace(Result, '{chat}', ChatName, [rfReplaceAll]);
  Result := StringReplace(Result, '{chatindex}', ChatIndex, [rfReplaceAll]);
end;

procedure TCustomTermManager.DoRoute(const ALine, APayload: string; var AKind: TTermInputKind; var AAllow: boolean);
begin
  if Assigned(FOnRoute) then
    FOnRoute(Self, ALine, APayload, AKind, AAllow);
end;

procedure TCustomTermManager.DoOutput(const AText: string; AIsStderr: boolean);
var
  I, Start, BreakLength: integer;
begin
  // Accumulate output of the currently running command for the shell log
  if FCapturing and FShellHistory.Enabled then
  begin
    if Length(FCaptureOutput) < FShellHistory.MaxOutputBytes * 2 then
      FCaptureOutput := FCaptureOutput + AText;
    if AIsStderr then
      FCaptureError := True;
  end;

  if not AIsStderr then
  begin
    WriteText(AText, False);
    Exit;
  end;

  // Color non-empty error text without coloring line breaks
  Start := 1;
  I := 1;

  while I <= Length(AText) do
  begin
    if AText[I] in [#10, #13] then
    begin
      if I > Start then
      begin
        SetColor(tcErrorBadge);
        try
          WriteText(Copy(AText, Start, I - Start), True);
        finally
          SetColor(tcDefault);
        end;
      end;

      BreakLength := 1;
      if (AText[I] = #13) and (I < Length(AText)) and (AText[I + 1] = #10) then
        BreakLength := 2;

      WriteText(Copy(AText, I, BreakLength), True);
      Inc(I, BreakLength);
      Start := I;
    end
    else
      Inc(I);
  end;

  if Start <= Length(AText) then
  begin
    SetColor(tcErrorBadge);
    try
      WriteText(Copy(AText, Start, MaxInt), True);
    finally
      SetColor(tcDefault);
    end;
  end;
end;

procedure TCustomTermManager.DoAgentExecute(const AText: string);
begin
  if Assigned(FOnAgentExecute) then
    FOnAgentExecute(Self, AText);
end;

procedure TCustomTermManager.DoExit(AExitCode: integer);
begin
  if Assigned(FOnExit) then
    FOnExit(Self, AExitCode);
end;

function TCustomTermManager.IsExternalCommand(const AName: string): boolean;
const
  {$IFDEF WINDOWS}
  CMD_BUILTINS =
    '|assoc|break|call|cd|chcp|chdir|cls|color|copy|date|del|dir|doskey|' +
    'echo|endlocal|erase|exit|for|ftype|goto|if|md|mkdir|mklink|move|' +
    'path|pause|popd|prompt|pushd|rd|rem|ren|rename|rmdir|set|setlocal|' + 'shift|start|time|title|type|ver|verify|vol|';

  POWERSHELL_BUILTINS =
    '|begin|break|catch|class|continue|do|else|elseif|end|exit|filter|' +
    'finally|for|foreach|function|if|in|param|process|return|switch|' + 'throw|trap|try|until|while|' +
    'get-childitem|gci|dir|ls|get-content|gc|set-content|sc|' + 'get-location|gl|pwd|set-location|sl|cd|push-location|pushd|' +
    'pop-location|popd|write-output|echo|write-host|write-error|' + 'write-warning|write-verbose|write-debug|select-object|select|' +
    'where-object|where|foreach-object|%|new-item|ni|remove-item|ri|' +
    'copy-item|copy|move-item|move|test-path|resolve-path|get-command|' +
    'get-process|gps|stop-process|kill|get-service|start-service|' +
    'stop-service|export-csv|import-csv|convertto-json|convertfrom-json|' +
    'measure-object|sort-object|group-object|format-table|ft|format-list|fl|' +
    'clear-host|cls|help|man|history|h|set-variable|sv|get-variable|gv|' +
    'remove-variable|rv|set-alias|sal|get-alias|gal|remove-alias|';
  {$ELSE}
  UNIX_BUILTINS =
    '|alias|bg|bind|break|builtin|caller|cd|command|compgen|complete|' +
    'continue|declare|dirs|disown|echo|enable|eval|exec|exit|export|' +
    'false|fc|fg|getopts|hash|help|history|jobs|kill|let|local|logout|' +
    'mapfile|popd|printf|pushd|pwd|read|readonly|return|set|shift|' + 'shopt|source|suspend|test|times|trap|true|type|typeset|ulimit|' +
    'umask|unalias|unset|wait|';
  {$ENDIF}
var
  EnvPath, KnownCommands: string;
begin
  case DetectShellFamily(FShellExec) of
    sfCmd:
      KnownCommands := CMD_BUILTINS;
    sfPowerShell:
      KnownCommands := POWERSHELL_BUILTINS;
    {$IFNDEF WINDOWS}
    sfUnix:
      KnownCommands := UNIX_BUILTINS;
    {$ENDIF}
    else
      KnownCommands := string.Empty;
  end;

  // Check shell-specific builtins first
  if Pos('|' + LowerCase(AName) + '|', KnownCommands) > 0 then
    Exit(True);

  if DetectShellFamily(FShellExec) = sfPowerShell then
  begin
    // Recognize PowerShell static .NET method calls
    if (AName <> '') and (AName[1] = '[') and (Pos(']::', AName) > 0) then
      Exit(True);

    // Recognize PowerShell variable expressions
    if (AName <> '') and (AName[1] = '$') then
      Exit(True);
  end;

  EnvPath := SysUtils.GetEnvironmentVariable('PATH');

  // Search executable files in PATH
  Result := FileSearch(AName, EnvPath) <> '';

  {$IFDEF WINDOWS}
  Result := Result or (FileSearch(AName + '.exe', EnvPath) <> '') or
    (FileSearch(AName + '.bat', EnvPath) <> '') or
    (FileSearch(AName + '.cmd', EnvPath) <> '') or
    (FileSearch(AName + '.com', EnvPath) <> '');
  {$ENDIF}
end;

function TCustomTermManager.ClassifyLine(const ALine: string; out APayload: string): TTermInputKind;
var
  S, FirstLine, First, GroupCommand: string;
  P, I, GroupPos: integer;
  HasMultipleLines, InQuotes: boolean;
begin
  APayload := '';
  S := Trim(ALine);
  if S = '' then
    Exit(tikEmpty);

  HasMultipleLines := (Pos(#10, S) > 0) or (Pos(#13, S) > 0);

  // Special case: bare "?" shows agent help, "? text" still routes to agent
  if FUsePrefixes and (S = '?') then
  begin
    APayload := S;
    Exit(tikBuiltin);
  end;

  // Prefixes force routing and are stripped from payload
  if FUsePrefixes then
  begin
    if S[1] = '!' then
    begin
      APayload := Trim(Copy(S, 2, MaxInt));
      Exit(tikCommand);
    end;
    if S[1] = '?' then
    begin
      APayload := Trim(Copy(S, 2, MaxInt));
      Exit(tikAgent);
    end;
  end;

  APayload := S;

  // Classify using only the first line of a pasted block
  FirstLine := S;
  P := Pos(#10, FirstLine);
  if P = 0 then
    P := Pos(#13, FirstLine);

  if P > 0 then
    SetLength(FirstLine, P - 1);

  FirstLine := Trim(FirstLine);

  // Extract the first command token, including quoted executable paths
  if (FirstLine <> '') and (FirstLine[1] = '"') then
  begin
    P := Pos('"', Copy(FirstLine, 2, MaxInt));
    if P > 0 then
      First := Copy(FirstLine, 2, P - 1)
    else
      First := Copy(FirstLine, 2, MaxInt);
  end
  else
  begin
    P := 1;
    while (P <= Length(FirstLine)) and not (FirstLine[P] in [#9, ' ']) do
      Inc(P);
    First := Copy(FirstLine, 1, P - 1);
  end;

  First := LowerCase(First);

  // Support batch commands prefixed with @
  while (First <> '') and (First[1] = '@') do
    Delete(First, 1, 1);

  // Application builtins must take precedence over shell commands
  if FBuiltinCommands.IndexOf(ExtractFileName(StringReplace(First, '\', '/', [rfReplaceAll]))) >= 0 then
    Exit(tikBuiltin);

  // PowerShell variable assignments and console methods are valid commands
  if DetectShellFamily(FShellExec) = sfPowerShell then
  begin
    if (FirstLine <> '') and (FirstLine[1] = '$') then
      Exit(tikCommand);

    if Pos('[Console]::', FirstLine) = 1 then
      Exit(tikCommand);
  end;

  // Detect cmd.exe command groups and shell operators outside quotes
  if DetectShellFamily(FShellExec) = sfCmd then
  begin
    // Recognize a command group only when it starts the input
    if (FirstLine <> '') and (FirstLine[1] = '(') then
    begin
      GroupPos := 1;

      // Skip opening parentheses and whitespace
      while (GroupPos <= Length(S)) and (S[GroupPos] in ['(', ' ', #9, #10, #13]) do
        Inc(GroupPos);

      GroupCommand := string.Empty;

      // Extract the first command token, including quoted executable paths
      if GroupPos <= Length(S) then
      begin
        if S[GroupPos] = '"' then
        begin
          Inc(GroupPos);
          P := GroupPos;

          while (GroupPos <= Length(S)) and (S[GroupPos] <> '"') do
            Inc(GroupPos);

          GroupCommand := Copy(S, P, GroupPos - P);
        end
        else
        begin
          P := GroupPos;

          while (GroupPos <= Length(S)) and not (S[GroupPos] in [' ', #9, #10, #13, '(', ')']) do
            Inc(GroupPos);

          GroupCommand := Copy(S, P, GroupPos - P);
        end;
      end;

      GroupCommand := LowerCase(ExtractFileName(StringReplace(GroupCommand, '\', '/', [rfReplaceAll])));

      // Support batch commands prefixed with @
      while (GroupCommand <> '') and (GroupCommand[1] = '@') do
        Delete(GroupCommand, 1, 1);

      // Only route actual shell commands as command groups
      if (GroupCommand <> '') and ((FBuiltinCommands.IndexOf(GroupCommand) >= 0) or IsExternalCommand(GroupCommand)) then
        Exit(tikCommand);
    end;

    // Detect shell operators outside quotes
    InQuotes := False;
    I := 1;

    while I <= Length(S) do
    begin
      if S[I] = '^' then
      begin
        Inc(I, 2);
        Continue;
      end;

      if S[I] = '"' then
        InQuotes := not InQuotes
      else if not InQuotes and (S[I] in ['&', '|', '<', '>']) then
        Exit(tikCommand);

      Inc(I);
    end;
  end;

  // Detect drive switches before extracting the executable name
  if (DetectShellFamily(FShellExec) in [sfCmd, sfPowerShell]) and (Length(First) >= 2) and (First[2] = ':') and
    (First[1] in ['a'..'z']) and ((Length(First) = 2) or ((Length(First) >= 3) and (First[3] in [PathDelim, '/']))) then
  begin
    if HasMultipleLines then
      Exit(tikCommand);

    APayload := S;
    Exit(tikBuiltin);
  end;

  First := ExtractFileName(StringReplace(First, '\', '/', [rfReplaceAll]));

  // Handle glued cd variants like cd.., cd\, cd/ the same way cmd.exe does
  if (Length(First) > 2) and (Copy(First, 1, 2) = 'cd') and (First[3] in ['.', PathDelim, '/']) then
  begin
    if HasMultipleLines then
      Exit(tikCommand);

    APayload := 'cd ' + Copy(S, 3, MaxInt);
    Exit(tikBuiltin);
  end;

  // Multi-line shell input must take precedence over external executables
  if HasMultipleLines and FSearchPath and IsExternalCommand(First) then
    Exit(tikCommand);

  if FSearchPath and IsExternalCommand(First) then
    Exit(tikCommand);

  Result := tikAgent;
end;

procedure TCustomTermManager.HandleBuiltin(const ALine: string);
var
  Cmd, Arg, TargetPath: string;
  P, I: integer;
begin
  P := Pos(' ', ALine);
  if P > 0 then
  begin
    Cmd := LowerCase(Copy(ALine, 1, P - 1));
    Arg := Trim(Copy(ALine, P + 1, MaxInt));
  end
  else
  begin
    Cmd := LowerCase(ALine);
    Arg := '';
  end;

  if (Cmd = 'exit') or (Cmd = 'quit') then
    FRunning := False
  else if (Length(Cmd) >= 2) and (Cmd[2] = ':') and (Cmd[1] in ['a'..'z']) and ((Length(Cmd) = 2) or (Cmd[3] in [PathDelim, '/'])) then
  begin
    // Drive switch "d:", "d:\", "d:\path" — go to the drive or subfolder
    if Length(Cmd) = 2 then
      TargetPath := UpCase(Cmd[1]) + ':\'
    else
      TargetPath := IncludeTrailingPathDelimiter(UpCase(Cmd[1]) + ':') + Copy(ALine, 4, MaxInt);
    TargetPath := ExpandFileName(TargetPath);
    if DirectoryExists(TargetPath) then
      SetPath(TargetPath)
    else
      DoOutput('Directory not found: ' + ALine + LineEnding, True);
  end
  else if Cmd = 'cd' then
  begin
    // Strip /d flag that cmd.exe uses to also switch the drive
    if (Length(Arg) >= 3) and (LowerCase(Copy(Arg, 1, 3)) = '/d ') then
      Arg := Trim(Copy(Arg, 4, MaxInt));
    if Arg = '' then
      DoOutput(GetEffectivePath + LineEnding, False)
    else
    begin
      if IsAbsolutePath(Arg) then
        TargetPath := Arg
      else
        TargetPath := IncludeTrailingPathDelimiter(GetEffectivePath) + Arg;
      TargetPath := ExpandFileName(TargetPath);
      if DirectoryExists(TargetPath) then
        SetPath(TargetPath)
      else
        DoOutput('Directory not found: ' + Arg + LineEnding, True);
    end;
  end
  else if Cmd = 'pwd' then
    DoOutput(GetEffectivePath + LineEnding, False)
  else if (Cmd = 'cls') or (Cmd = 'clear') then
  begin
    if Assigned(FAgent) then
    begin
      // Clear the current chat without creating a new one
      FAgent.ClearHistory;
      FAgent.ResetUsage;
      if Assigned(FAgent.ActiveChat) then
      begin
        FAgent.ActiveChat.TerminalOutput := string.Empty;
        FAgent.ActiveChat.ShellLog.Clear;
        FAgent.ActiveChat.MarkSessionActive;
      end;
    end;

    FShellLog.Clear;
    ClearScreen;
  end
  else if Cmd = 'new' then
  begin
    if not Assigned(FAgent) then
    begin
      DoOutput('error: agent is not attached' + LineEnding, True);
      Exit;
    end;

    if not Assigned(FAgent.NewChat(string.Empty)) then
      Exit;

    FHistory.Clear;
    FShellLog.Clear;
    ClearScreen;
  end
  else if Cmd = 'history' then
  begin
    for I := 0 to FHistory.Count - 1 do
      DoOutput(Format('%4d  %s%s', [I + 1, FHistory[I], LineEnding]), False);
  end
  else if (Cmd = 'help') or (Cmd = 'h') or (Cmd = '?') then
    HandleHelpCommand(Cmd <> 'help')
  else if Cmd = 'set' then
    HandleSetCommand(Arg)
  else if Cmd = 'get' then
    HandleGetCommand(Arg)
  else if (Cmd = 'config') or (Cmd = 'settings') then
  begin
    DoOutput(FormatAgentConfig(FAgent) + LineEnding, False);
    DoOutput(FormatTermConfig + LineEnding, False);
  end
  else if Cmd = 'models' then
    HandleModelsCommand(Arg)
  else if Cmd = 'ollama' then
    HandleOllamaCommand(Arg)
  else
    DoOutput('Unknown builtin: ' + Cmd + LineEnding, True);
end;

procedure TCustomTermManager.HandleHelpCommand(AShort: boolean);
begin
  if AShort then
    DoOutput(FormatShortHelp + LineEnding, False)
  else
    DoOutput(FormatFullHelp + LineEnding, False);
end;

procedure TCustomTermManager.HandleSetCommand(const AArg: string);
var
  P: integer;
  PropName, PropValue, ErrMsg: string;
begin
  if Trim(AArg) = '' then
  begin
    DoOutput('usage: set <name> <value>' + LineEnding, True);
    DoOutput('use "help" for property lists' + LineEnding, True);
    Exit;
  end;

  // Split property name and value at the first whitespace character
  P := 1;
  while (P <= Length(AArg)) and not (AArg[P] in [#9, #10, #13, ' ']) do
    Inc(P);

  if P <= Length(AArg) then
  begin
    PropName := Copy(AArg, 1, P - 1);
    PropValue := Trim(Copy(AArg, P + 1, MaxInt));
  end
  else
  begin
    PropName := Trim(AArg);
    PropValue := string.Empty;
  end;

  if LowerCase(PropName) = 'chat' then
  begin
    if not Assigned(FAgent) or not Assigned(FAgent.ActiveChat) then
    begin
      DoOutput('error: agent is not attached' + LineEnding, True);
      Exit;
    end;

    if PropValue = string.Empty then
    begin
      DoOutput('usage: set chat <name>' + LineEnding, True);
      Exit;
    end;

    // Strip surrounding quotes from the chat name
    if (Length(PropValue) >= 2) and (PropValue[1] = '"') and (PropValue[Length(PropValue)] = '"') then
      PropValue := Copy(PropValue, 2, Length(PropValue) - 2);

    FAgent.ActiveChat.Name := PropValue;
    DoOutput('chat = ' + PropValue + LineEnding, False);
  end
  else if LowerCase(PropName) = 'chatprompt' then
  begin
    if not Assigned(FAgent) or not Assigned(FAgent.ActiveChat) then
    begin
      DoOutput('error: agent is not attached' + LineEnding, True);
      Exit;
    end;

    // Strip surrounding quotes to allow clearing the prompt
    if (Length(PropValue) >= 2) and (PropValue[1] = '"') and (PropValue[Length(PropValue)] = '"') then
      PropValue := Copy(PropValue, 2, Length(PropValue) - 2);

    FAgent.ActiveChat.ChatPrompt := PropValue;
    DoOutput('chatprompt = ' + PropValue + LineEnding, False);
  end
  // term.* properties are handled locally, everything else goes to the agent
  else if LowerCase(Copy(PropName, 1, 5)) = 'term.' then
    HandleTermSet(Copy(PropName, 6, MaxInt), PropValue)
  else if SetAgentProperty(FAgent, PropName, PropValue, ErrMsg) then
    DoOutput(PropName + ' = ' + PropValue + LineEnding, False)
  else
    DoOutput('error: ' + ErrMsg + LineEnding, True);
end;

procedure TCustomTermManager.HandleGetCommand(const AArg: string);
var
  Value, ErrMsg: string;
begin
  if Trim(AArg) = '' then
  begin
    DoOutput('usage: get <name>' + LineEnding, True);
    DoOutput('use "help" for property lists' + LineEnding, True);
    Exit;
  end;
  if LowerCase(Trim(AArg)) = 'chatprompt' then
  begin
    if not Assigned(FAgent) or not Assigned(FAgent.ActiveChat) then
    begin
      DoOutput('error: agent is not attached' + LineEnding, True);
      Exit;
    end;

    DoOutput('chatprompt = ' + FAgent.ActiveChat.ChatPrompt + LineEnding, False);
    Exit;
  end;

  // term.* properties are handled locally, everything else goes to the agent
  if LowerCase(Copy(Trim(AArg), 1, 5)) = 'term.' then
  begin
    HandleTermGet(Copy(Trim(AArg), 6, MaxInt));
    Exit;
  end;
  if not GetAgentProperty(FAgent, Trim(AArg), Value, ErrMsg) then
  begin
    DoOutput('error: ' + ErrMsg + LineEnding, True);
    Exit;
  end;
  DoOutput(AArg + ' = ' + Value + LineEnding, False);
end;

procedure TCustomTermManager.HandleTermSet(const AName, AValue: string);
var
  N: string;
  IntVal: integer;
  BoolVal: boolean;
  V: string;
  ColorVal: TConsoleColor;
  Parts: TStringList;
  Role, Part: string;
  Pair: TConsoleColorPair;
begin
  N := LowerCase(Trim(AName));
  V := Trim(AValue);

  // Strip surrounding quotes for string values
  if (Length(V) >= 2) and (V[1] = '"') and (V[Length(V)] = '"') then
    V := Copy(V, 2, Length(V) - 2);

  if N = 'path' then
  begin
    if V = '' then
    begin
      DoOutput('error: term.path cannot be empty' + LineEnding, True);
      Exit;
    end;
    SetPath(V);
  end
  else if N = 'shell' then
  begin
    if V = '' then
    begin
      DoOutput('error: term.shell cannot be empty' + LineEnding, True);
      Exit;
    end;
    FShellExec := V;
  end
  else if N = 'showthinking' then
  begin
    case LowerCase(V) of
      'on', 'true', 'yes', '1': BoolVal := True;
      'off', 'false', 'no', '0': BoolVal := False;
      else
        DoOutput('error: term.showthinking must be on/off, true/false, yes/no' + LineEnding, True);
        Exit;
    end;
    FShowThinking := BoolVal;
  end
  else if N = 'color' then
  begin
    Parts := TStringList.Create;
    try
      Parts.Delimiter := ' ';
      Parts.StrictDelimiter := True;
      Parts.DelimitedText := StringReplace(V, #9, ' ', [rfReplaceAll]);

      if (Parts.Count <> 2) and (Parts.Count <> 3) then
      begin
        DoOutput('usage: set term.color <role> [foreground|background] <color>' + LineEnding, True);
        Exit;
      end;

      Role := LowerCase(Parts[0]);
      Pair := nil;

      // Markdown colors use a single foreground color
      if Copy(Role, 1, 8) = 'markdown' then
      begin
        if (Parts.Count <> 2) or not TryParseTermColor(Parts[1], ColorVal) then
        begin
          DoOutput('usage: set term.color markdown.<role> <color>' + LineEnding, True);
          Exit;
        end;

        if Role = 'markdown.marker' then
          FColors.Markdown.Marker := ColorVal
        else if Role = 'markdown.bold' then
          FColors.Markdown.Bold := ColorVal
        else if Role = 'markdown.italic' then
          FColors.Markdown.Italic := ColorVal
        else if Role = 'markdown.strikethrough' then
          FColors.Markdown.Strikethrough := ColorVal
        else if Role = 'markdown.inlinecode' then
          FColors.Markdown.InlineCode := ColorVal
        else if Role = 'markdown.fencedcode' then
          FColors.Markdown.FencedCode := ColorVal
        else if Role = 'markdown.highlight' then
          FColors.Markdown.Highlight := ColorVal
        else if Role = 'markdown.heading' then
          FColors.Markdown.Heading := ColorVal
        else if Role = 'markdown.quote' then
          FColors.Markdown.Quote := ColorVal
        else if Role = 'markdown.listmarker' then
          FColors.Markdown.ListMarker := ColorVal
        else
        begin
          DoOutput('error: unknown Markdown color role: ' + Role + LineEnding, True);
          Exit;
        end;

        DoOutput('term.color ' + Role + ' = ' + TermColorName(ColorVal) + LineEnding, False);
        Exit;
      end;

      if Parts.Count = 2 then
      begin
        if not TryParseTermColor(Parts[1], ColorVal) then
        begin
          DoOutput('error: invalid color name' + LineEnding, True);
          Exit;
        end;

        if Role = 'defaulttext' then
          FColors.DefaultText := ColorVal
        else if Role = 'thinkingtext' then
          FColors.ThinkingText := ColorVal
        else
        begin
          DoOutput('error: this color role requires foreground or background' + LineEnding, True);
          Exit;
        end;
      end
      else
      begin
        Part := LowerCase(Parts[1]);

        if not TryParseTermColor(Parts[2], ColorVal) then
        begin
          DoOutput('error: invalid color name' + LineEnding, True);
          Exit;
        end;

        if Role = 'welcomebadge' then
          Pair := FColors.WelcomeBadge
        else if Role = 'thinkingbadge' then
          Pair := FColors.ThinkingBadge
        else if Role = 'toolbadge' then
          Pair := FColors.ToolBadge
        else if Role = 'errorbadge' then
          Pair := FColors.ErrorBadge
        else if Role = 'warnbadge' then
          Pair := FColors.WarnBadge
        else if Role = 'promptinput' then
          Pair := FColors.PromptInput
        else if Role = 'log' then
          Pair := FColors.Log
        else
        begin
          DoOutput('error: unknown color role: ' + Role + LineEnding, True);
          Exit;
        end;

        if Part = 'foreground' then
          Pair.Foreground := ColorVal
        else if Part = 'background' then
          Pair.Background := ColorVal
        else
        begin
          DoOutput('error: expected foreground or background' + LineEnding, True);
          Exit;
        end;
      end;
    finally
      Parts.Free;
    end;
  end
  else if N = 'commandtimeout' then
  begin
    if not TryStrToInt(V, IntVal) or (IntVal < 0) then
    begin
      DoOutput('error: term.commandtimeout must be a non-negative integer' + LineEnding, True);
      Exit;
    end;
    FCommandTimeout := IntVal;
  end
  else if N = 'maxcapturebytes' then
  begin
    if not TryStrToInt(V, IntVal) or (IntVal <= 0) then
    begin
      DoOutput('error: term.maxcapturebytes must be a positive integer' + LineEnding, True);
      Exit;
    end;
    FMaxCaptureBytes := IntVal;
  end
  else if N = 'agentcommandtimeout' then
  begin
    if not TryStrToInt(V, IntVal) or (IntVal < 0) then
    begin
      DoOutput('error: term.agentcommandtimeout must be a non-negative integer' + LineEnding, True);
      Exit;
    end;
    FAgentCommandTimeout := IntVal;
  end
  else
  begin
    DoOutput('error: unknown term property: ' + AName + ', use "help agent"' + LineEnding, True);
    Exit;
  end;

  DoOutput('term.' + N + ' = ' + V + LineEnding, False);
end;

procedure TCustomTermManager.HandleTermGet(const AName: string);
var
  N: string;
  Val: string;
  T: TStringList;

// Formats a foreground/background color pair
  function PairValue(const APair: TConsoleColorPair): string;
  begin
    Result := 'foreground ' + TermColorName(APair.Foreground) + ', background ' + TermColorName(APair.Background);
  end;

begin
  N := LowerCase(Trim(AName));

  if N = 'color' then
  begin
    T := TStringList.Create;
    try
      T.Add('Terminal colors:');
      T.Add('  defaulttext    ' + TermColorName(FColors.DefaultText));
      T.Add('  thinkingtext   ' + TermColorName(FColors.ThinkingText));
      T.Add('  welcomebadge   ' + PairValue(FColors.WelcomeBadge));
      T.Add('  thinkingbadge  ' + PairValue(FColors.ThinkingBadge));
      T.Add('  toolbadge      ' + PairValue(FColors.ToolBadge));
      T.Add('  errorbadge     ' + PairValue(FColors.ErrorBadge));
      T.Add('  warnbadge      ' + PairValue(FColors.WarnBadge));
      T.Add('  promptinput    ' + PairValue(FColors.PromptInput));
      T.Add('  log            ' + PairValue(FColors.Log));
      T.Add('  markdown.marker       ' + TermColorName(FColors.Markdown.Marker));
      T.Add('  markdown.bold         ' + TermColorName(FColors.Markdown.Bold));
      T.Add('  markdown.italic       ' + TermColorName(FColors.Markdown.Italic));
      T.Add('  markdown.strikethrough ' + TermColorName(FColors.Markdown.Strikethrough));
      T.Add('  markdown.inlinecode   ' + TermColorName(FColors.Markdown.InlineCode));
      T.Add('  markdown.highlight    ' + TermColorName(FColors.Markdown.Highlight));
      T.Add('  markdown.heading      ' + TermColorName(FColors.Markdown.Heading));
      T.Add('  markdown.quote        ' + TermColorName(FColors.Markdown.Quote));
      T.Add('  markdown.listmarker   ' + TermColorName(FColors.Markdown.ListMarker));
      T.Add('  markdown.fencedcode  ' + TermColorName(FColors.Markdown.FencedCode));
      Val := T.Text;
    finally
      T.Free;
    end;
    DoOutput(Val, False);
    Exit;
  end
  else if N = 'path' then
    Val := GetEffectivePath
  else if N = 'shell' then
    Val := FShellExec
  else if N = 'showthinking' then
  begin
    if FShowThinking then
      Val := 'on'
    else
      Val := 'off';
  end
  else if N = 'commandtimeout' then
    Val := IntToStr(FCommandTimeout)
  else if N = 'maxcapturebytes' then
    Val := IntToStr(FMaxCaptureBytes)
  else if N = 'agentcommandtimeout' then
    Val := IntToStr(FAgentCommandTimeout)
  else
  begin
    DoOutput('error: unknown term property: ' + AName + ', use "help agent"' + LineEnding, True);
    Exit;
  end;

  DoOutput('term.' + N + ' = ' + Val + LineEnding, False);
end;

function TCustomTermManager.FormatTermConfig: string;
var
  T: TStringList;

// Adds an aligned setting row
  procedure Row(const AName, AValue: string);
  var
    Col: string;
  begin
    Col := '  ' + AName;
    while Length(Col) < 34 do
      Col := Col + ' ';
    T.Add(Col + ': ' + AValue);
  end;

  // Formats a foreground/background color pair
  function PairValue(const APair: TConsoleColorPair): string;
  begin
    Result := 'foreground ' + TermColorName(APair.Foreground) + ', background ' + TermColorName(APair.Background);
  end;

begin
  T := TStringList.Create;
  try
    T.Add('Terminal');
    Row('term.path', GetEffectivePath);
    Row('term.shell', FShellExec);
    Row('term.showthinking', BoolToStr(FShowThinking, 'on', 'off'));
    Row('term.commandtimeout', IntToStr(FCommandTimeout));
    Row('term.maxcapturebytes', IntToStr(FMaxCaptureBytes));
    Row('term.agentcommandtimeout', IntToStr(FAgentCommandTimeout));

    T.Add('');
    T.Add('Terminal colors');
    Row('defaulttext', TermColorName(FColors.DefaultText));
    Row('thinkingtext', TermColorName(FColors.ThinkingText));
    Row('welcomebadge', PairValue(FColors.WelcomeBadge));
    Row('thinkingbadge', PairValue(FColors.ThinkingBadge));
    Row('toolbadge', PairValue(FColors.ToolBadge));
    Row('errorbadge', PairValue(FColors.ErrorBadge));
    Row('warnbadge', PairValue(FColors.WarnBadge));
    Row('promptinput', PairValue(FColors.PromptInput));
    Row('log', PairValue(FColors.Log));
    Row('markdown.marker', TermColorName(FColors.Markdown.Marker));
    Row('markdown.bold', TermColorName(FColors.Markdown.Bold));
    Row('markdown.italic', TermColorName(FColors.Markdown.Italic));
    Row('markdown.strikethrough', TermColorName(FColors.Markdown.Strikethrough));
    Row('markdown.inlinecode', TermColorName(FColors.Markdown.InlineCode));
    Row('markdown.highlight', TermColorName(FColors.Markdown.Highlight));
    Row('markdown.heading', TermColorName(FColors.Markdown.Heading));
    Row('markdown.quote', TermColorName(FColors.Markdown.Quote));
    Row('markdown.listmarker', TermColorName(FColors.Markdown.ListMarker));
    Row('markdown.fencedcode', TermColorName(FColors.Markdown.FencedCode));
    Result := T.Text;
  finally
    T.Free;
  end;
end;

function TCustomTermManager.ReadSmallTextFile(const APath: string): string;
var
  Stream: TFileStream;
  Buf: rawbytestring = '';
  ReadCount: int64;
begin
  Result := string.Empty;

  if not FileExists(APath) then
    Exit;

  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Buf, Stream.Size);

    if Length(Buf) > 0 then
    begin
      ReadCount := Stream.Read(Buf[1], Length(Buf));
      SetLength(Buf, ReadCount);
      Result := string(UTF8Decode(Buf));
    end;
  finally
    Stream.Free;
  end;
end;

function TCustomTermManager.WaitOllamaOp(ATimeoutMs: integer): boolean;
var
  StartTick: QWord;
begin
  StartTick := GetTickCount64;
  while not FOllamaOpDone do
  begin
    CheckSynchronize(50);
    if GetTickCount64 - StartTick >= QWord(ATimeoutMs) then
      Exit(False);
  end;
  Result := True;
end;

procedure TCustomTermManager.HandleOllamaModelsRefreshed(Sender: TObject; const Models: TStringList);
begin
  // Done when the awaited model is present or when no specific model was set
  if FOllamaWaitModel = '' then
    FOllamaOpDone := True
  else if Models.IndexOf(FOllamaWaitModel) >= 0 then
    FOllamaOpDone := True;
end;

procedure TCustomTermManager.HandleOllamaError(Sender: TObject; Kind: TOllamaErrorKind; const ModelName, Msg: string);
begin
  if Kind = oekNone then
    Exit;
  FOllamaOpKind := Kind;
  FOllamaOpError := Msg;
  FOllamaOpDone := True;
end;

procedure TCustomTermManager.HandleOllamaPullProgress(Sender: TObject; const ModelName: string; Percent: integer);
var
  Step: integer;
begin
  if Percent < 0 then
    Exit;
  FOllamaPullPct := Percent;
  Step := Percent div 10;
  if (Step <> FOllamaPullLastStep) or (Percent = 100) then
  begin
    FOllamaPullLastStep := Step;
    DoOutput(Format('  %d%%', [Percent]) + LineEnding, False);
  end;
end;

procedure TCustomTermManager.HandleOllamaCommand(const AArg: string);
var
  Parts: TStringList;
  Sub: string;
  Value: integer;
begin
  if not Assigned(FAgent) then
  begin
    DoOutput('error: no agent attached' + LineEnding, True);
    Exit;
  end;
  if not Assigned(FAgent.OllamaManager) then
  begin
    DoOutput('error: agent has no OllamaManager' + LineEnding, True);
    Exit;
  end;
  if Trim(AArg) = '' then
  begin
    DoOutput(FormatOllamaHelp, False);
    Exit;
  end;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ' ';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Trim(AArg);
    if Parts.Count = 0 then
    begin
      DoOutput(FormatOllamaHelp, False);
      Exit;
    end;
    Sub := LowerCase(Parts[0]);
    if (Sub = 'list') or (Sub = 'ls') then
      HandleOllamaList
    else if Sub = 'ps' then
      HandleOllamaPs
    else if Sub = 'show' then
    begin
      if Parts.Count < 2 then
      begin
        DoOutput('usage: ollama show <model>' + LineEnding, True);
        Exit;
      end;
      HandleOllamaShow(Parts[1]);
    end
    else if Sub = 'pull' then
    begin
      if Parts.Count < 2 then
      begin
        DoOutput('usage: ollama pull <model>' + LineEnding, True);
        Exit;
      end;
      HandleOllamaPull(Parts[1]);
    end
    else if (Sub = 'rm') or (Sub = 'delete') then
    begin
      if Parts.Count < 2 then
      begin
        DoOutput('usage: ollama rm <model>' + LineEnding, True);
        Exit;
      end;
      HandleOllamaRm(Parts[1]);
    end
    else if Sub = 'stop' then
    begin
      if Parts.Count < 2 then
      begin
        DoOutput('usage: ollama stop <model>' + LineEnding, True);
        Exit;
      end;
      HandleOllamaStop(Parts[1]);
    end
    else if Sub = 'load' then
    begin
      if Parts.Count < 2 then
      begin
        DoOutput('usage: ollama load <model>' + LineEnding, True);
        Exit;
      end;
      HandleOllamaLoad(Parts[1]);
    end
    else if Sub = 'unload' then
    begin
      if Parts.Count < 2 then
      begin
        DoOutput('usage: ollama unload <model>' + LineEnding, True);
        Exit;
      end;
      HandleOllamaUnload(Parts[1]);
    end
    else if Sub = 'copy' then
    begin
      if Parts.Count < 3 then
      begin
        DoOutput('usage: ollama copy <source> <destination>' + LineEnding, True);
        Exit;
      end;
      HandleOllamaCopy(Parts[1], Parts[2]);
    end
    else if Sub = 'create' then
    begin
      if Parts.Count < 3 then
      begin
        DoOutput('usage: ollama create <name> <modelfile-path>' + LineEnding, True);
        Exit;
      end;
      HandleOllamaCreate(Parts[1], Parts[2]);
    end
    else if Sub = 'context' then
    begin
      if Parts.Count = 1 then
      begin
        Value := FAgent.OllamaManager.NumCtx;
        if Value = 0 then
          DoOutput('num_ctx: 0 (Ollama default)' + LineEnding, False)
        else
          DoOutput(Format('num_ctx: %d', [Value]) + LineEnding, False);
      end
      else if (Parts.Count <> 2) or not TryStrToInt(Parts[1], Value) or (Value < 0) then
        DoOutput('usage: ollama context [tokens], 0 = Ollama default' + LineEnding, True)
      else
      begin
        FAgent.OllamaManager.NumCtx := Value;
        FAgent.ContextTotal := Value;

        if Value = 0 then
          DoOutput('context reset to Ollama default' + LineEnding, False)
        else
          DoOutput(Format('context set to %d tokens', [Value]) + LineEnding, False);
      end;
    end
    else if (Sub = 'version') or (Sub = '--version') or (Sub = '-v') then
      HandleOllamaVersion
    else if (Sub = 'help') or (Sub = '--help') or (Sub = '-h') then
      DoOutput(FormatOllamaHelp, False)
    else
    begin
      DoOutput('error: unknown ollama subcommand: ' + Sub + LineEnding, True);
      DoOutput('use "ollama help" for the full list' + LineEnding, True);
    end;
  finally
    Parts.Free;
  end;
end;

procedure TCustomTermManager.HandleOllamaList;
var
  Mgr: TCustomOllamaManager;
  PrevRefreshed: TModelsRefreshedEvent;
  PrevError: TOllamaErrorEvent;
  I: integer;
begin
  Mgr := FAgent.OllamaManager;
  if not Mgr.Active then
  begin
    DoOutput('error: OllamaManager is inactive, enable with "set active on"' + LineEnding, True);
    Exit;
  end;
  DoOutput('Fetching model list from ' + Mgr.BaseURL + ' ...' + LineEnding, False);
  PrevRefreshed := Mgr.OnModelsRefreshed;
  PrevError := Mgr.OnError;
  Mgr.OnModelsRefreshed := @HandleOllamaModelsRefreshed;
  Mgr.OnError := @HandleOllamaError;
  try
    FOllamaWaitModel := '';
    FOllamaOpDone := False;
    FOllamaOpKind := oekNone;
    FOllamaOpError := '';
    Mgr.RefreshModels;
    if not WaitOllamaOp(15000) then
    begin
      DoOutput('error: timeout waiting for model list' + LineEnding, True);
      Exit;
    end;
  finally
    Mgr.OnModelsRefreshed := PrevRefreshed;
    Mgr.OnError := PrevError;
  end;
  if FOllamaOpKind <> oekNone then
  begin
    DoOutput('error: ' + FOllamaOpError + LineEnding, True);
    Exit;
  end;
  if Mgr.InstalledModels.Count = 0 then
  begin
    DoOutput('(no models installed)' + LineEnding, False);
    Exit;
  end;
  DoOutput(Format('Installed models (%d):', [Mgr.InstalledModels.Count]) + LineEnding, False);
  for I := 0 to Mgr.InstalledModels.Count - 1 do
    DoOutput('  ' + Mgr.InstalledModels[I] + LineEnding, False);
end;

function TCustomTermManager.BytesToHumanText(const ABytes: int64): string;
begin
  if ABytes >= int64(1024) * 1024 * 1024 then
    Result := FormatFloat('0.0', ABytes / (1024.0 * 1024 * 1024)) + ' GB'
  else if ABytes >= 1024 * 1024 then
    Result := FormatFloat('0.0', ABytes / (1024.0 * 1024)) + ' MB'
  else if ABytes >= 1024 then
    Result := FormatFloat('0.0', ABytes / 1024.0) + ' KB'
  else
    Result := IntToStr(ABytes) + ' B';
end;

procedure TCustomTermManager.RestoreTerminalHistory;
var
  Data: TJSONData;
  Messages: TJSONArray;
  Item: TJSONData;
  Entry: string;
  I: integer;
begin
  if not Assigned(FAgent) or not Assigned(FAgent.ActiveChat) or (FHistory.Count > 0) or (FAgent.ActiveChat.History = string.Empty) then
    Exit;

  Data := nil;
  try
    try
      Data := GetJSON(FAgent.ActiveChat.History);
      if not (Data is TJSONArray) then
        Exit;

      Messages := TJSONArray(Data);
      for I := 0 to Messages.Count - 1 do
      begin
        if not (Messages.Items[I] is TJSONObject) then
          Continue;

        Item := Messages.Items[I];
        if TJSONObject(Item).Get('role', string.Empty) <> 'user' then
          Continue;

        Entry := TJSONObject(Item).Get('content', string.Empty);
        if Entry = string.Empty then
          Continue;

        // Restore the agent prefix so the input is classified correctly
        if FUsePrefixes then
          Entry := '?' + Entry;

        if (FHistory.Count = 0) or (FHistory[FHistory.Count - 1] <> Entry) then
          FHistory.Add(Entry);
      end;

      while FHistory.Count > FHistoryMax do
        FHistory.Delete(0);

      FAgent.ActiveChat.TerminalHistory.Assign(FHistory);
    except
      FHistory.Clear;
    end;
  finally
    Data.Free;
  end;
end;

procedure TCustomTermManager.RestoreActiveChat;
begin
  if not Assigned(FAgent) or not Assigned(FAgent.ActiveChat) then
    Exit;

  // Restore the working directory of the active chat
  if DirectoryExists(FAgent.ActiveChat.WorkingDirectory) then
    Path := FAgent.ActiveChat.WorkingDirectory
  else
    FAgent.ActiveChat.WorkingDirectory := GetEffectivePath;

  FHistory.Assign(FAgent.ActiveChat.TerminalHistory);
  RestoreTerminalHistory;
  FShellLog.Assign(FAgent.ActiveChat.ShellLog);

  // Use the default output color when clearing the screen
  SetColor(tcDefault);
  ClearScreen;

  // Replay the saved terminal output without recording it a second time
  FRestoringChat := True;
  try
    ReplayChatOutput(FAgent.ActiveChat.TerminalOutput);
  finally
    FRestoringChat := False;
  end;
end;

function TCustomTermManager.RemoveLastInput: boolean;
var
  Chat: TAgentChat;
  Mark: TTerminalOutputMark;
  I: integer;
  {$IFDEF WINDOWS}
  Info: TConsoleScreenBufferInfo;
  Coord: TCoord;
  Count, Written: DWORD;
  DefaultAttr: Word;
  {$ENDIF}
begin
  Result := False;
  FLastInputScreenCleared := False;

  if not Assigned(FAgent) or not Assigned(FAgent.ActiveChat) then
    Exit;

  Chat := FAgent.ActiveChat;

  // Get the last operation boundary
  if not Chat.GetLastOutputMark(Mark) then
    Exit;

  if (Mark.OutputStart < 0) or (Mark.OutputStart > Length(Chat.TerminalOutput)) then
    Exit;

  if (Mark.InputKind < Ord(Low(TTermInputKind))) or (Mark.InputKind > Ord(High(TTermInputKind))) then
    Exit;

  // Remove the last agent exchange, including tool messages
  if (Mark.InputKind = Ord(tikAgent)) and not FAgent.RemoveLastExchange then
    Exit;

  // Remove shell log entries created by this operation
  for I := 1 to Mark.ShellLogCount do
  begin
    if FShellLog.Count = 0 then
      Break;
    FShellLog.Delete(FShellLog.Count - 1);
  end;

  Chat.ShellLog.Assign(FShellLog);

  // Remove terminal output starting from the saved position
  Chat.TerminalOutput := Copy(Chat.TerminalOutput, 1, Mark.OutputStart);

  // Remove the completed operation mark
  Chat.DeleteLastOutputMark;

  // Mark the chat as modified after removing the last operation
  Chat.MarkSessionActive;

  {$IFDEF WINDOWS}
  // Clear the screen buffer from the saved input position
  Info := Default(TConsoleScreenBufferInfo);
  if (Mark.ScreenRow >= 0) and (Mark.ScreenCol >= 0) and
    GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info) and
    (Mark.ScreenRow >= Info.srWindow.Top) and
    (Mark.ScreenRow <= Info.srWindow.Bottom) and
    (Mark.ScreenRow < Info.dwSize.Y) and
    (Mark.ScreenCol < Info.dwSize.X) then
  begin
    Coord.X := Mark.ScreenCol;
    Coord.Y := Mark.ScreenRow;
    Count := DWORD(Info.dwSize.X) * DWORD(Info.dwSize.Y - Mark.ScreenRow) -
      DWORD(Mark.ScreenCol);
    Written := 0;

    if (Count > 0) and
      FillConsoleOutputCharacter(GetStdHandle(STD_OUTPUT_HANDLE), ' ', Count, Coord, Written) and
      (Written = Count) then
    begin
      Written := 0;
      DefaultAttr := Info.wAttributes;

      // Get the default output attributes
      SetColor(tcDefault);
      if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info) then
        DefaultAttr := Info.wAttributes;

      if FillConsoleOutputAttribute(GetStdHandle(STD_OUTPUT_HANDLE), DefaultAttr,
        Count, Coord, Written) and (Written = Count) then
      begin
        // Restore the previous prompt attributes
        SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE),
          DefaultAttr xor (DefaultAttr xor Info.wAttributes));
        FLastInputScreenCleared :=
          SetConsoleCursorPosition(GetStdHandle(STD_OUTPUT_HANDLE), Coord);
      end;
    end;
  end;
  {$ENDIF}

  Result := True;
end;

function TCustomTermManager.ConfirmDeleteChat(const AChatName: string): boolean;
{$IFDEF WINDOWS}
var
  Handle: THandle;
  Rec: INPUT_RECORD;
  N: DWORD = 0;
  C: WideChar;
begin
  Result := False;
  Rec:=Default(INPUT_RECORD);

  Write('Delete chat "' + AChatName + '"? [y/N]: ');
  Flush(Output);

  Handle := GetStdHandle(STD_INPUT_HANDLE);
  if (Handle = 0) or (Handle = INVALID_HANDLE_VALUE) then
    Exit;

  while ReadConsoleInput(Handle, Rec, 1, N) do
  begin
    if (Rec.EventType <> KEY_EVENT) or not Rec.Event.KeyEvent.bKeyDown then
      Continue;

    C := Rec.Event.KeyEvent.UnicodeChar;

    if Rec.Event.KeyEvent.wVirtualKeyCode = VK_RETURN then
      Break;

    if (C = 'y') or (C = 'Y') then
    begin
      Result := True;
      Write('y');
      Break;
    end;

    if (C = 'n') or (C = 'N') or
      (Rec.Event.KeyEvent.wVirtualKeyCode = VK_ESCAPE) then
    begin
      Write('n');
      Break;
    end;
  end;

  WriteLine(string.Empty);
end;
  {$ELSE}
var
  Answer: string;
begin
  Write('Delete chat "' + AChatName + '"? [y/N]: ');
  ReadLn(Answer);
  Result := SameText(Trim(Answer), 'y') or SameText(Trim(Answer), 'yes');
end;
{$ENDIF}

procedure TCustomTermManager.HandleOllamaPs;
var
  Mgr: TCustomOllamaManager;
  PrevRefreshed: TModelsRefreshedEvent;
  PrevError: TOllamaErrorEvent;
  I: integer;
  ModelName, Json, ModelId, Digest, Runner, SizeStr, Processor, UntilText: string;
  Data: TJSONData;
  Obj: TJSONObject;
  Size, SizeVram, CtxLen: int64;
  CpuPct, GpuPct: integer;

// Decimal SI units with one decimal place, matches Ollama CLI HumanBytes2
  function HumanBytes2(const ABytes: int64): string;
  const
    UNITS: array[0..4] of string = ('B', 'KB', 'MB', 'GB', 'TB');
  var
    V: double;
    E: integer;
  begin
    if ABytes < 1000 then
      Exit(IntToStr(ABytes) + ' B');
    V := ABytes;
    E := 0;
    while (V >= 1000) and (E < 4) do
    begin
      V := V / 1000;
      Inc(E);
    end;
    Result := FormatFloat('0.0', V) + ' ' + UNITS[E];
  end;

  // Matches Ollama CLI HumanTime: Forever, Stopping..., N days/hours/minutes/seconds
  function HumanTime(const AExpiresAt: string): string;
  var
    Y, M, D, H, Mn, S: integer;
    ExpiresDate: TDateTime;
    DiffSec: int64;
    DiffDays: double;
  begin
    if AExpiresAt = '' then
      Exit('unknown');
    // Ollama emits YYYY-MM-DDTHH:MM:SS.nnnnnnnnn+HH:MM, parse fixed prefix only
    if Length(AExpiresAt) < 19 then
      Exit(AExpiresAt);
    Y := StrToIntDef(Copy(AExpiresAt, 1, 4), -1);
    M := StrToIntDef(Copy(AExpiresAt, 6, 2), -1);
    D := StrToIntDef(Copy(AExpiresAt, 9, 2), -1);
    H := StrToIntDef(Copy(AExpiresAt, 12, 2), -1);
    Mn := StrToIntDef(Copy(AExpiresAt, 15, 2), -1);
    S := StrToIntDef(Copy(AExpiresAt, 18, 2), -1);
    if (Y < 2000) or (M < 1) or (M > 12) or (D < 1) or (D > 31) or (H < 0) or (H > 23) or (Mn < 0) or
      (Mn > 59) or (S < 0) or (S > 60) then
      Exit(AExpiresAt);
    try
      ExpiresDate := EncodeDateTime(Y, M, D, H, Mn, S, 0);
    except
      Exit(AExpiresAt);
    end;
    // keep_alive of -1 makes Ollama report a year far in the future
    if Y > 2100 then
      Exit('Forever');
    // Ollama returns UTC, Now is local, compare in UTC to stay consistent
    DiffDays := ExpiresDate - LocalTimeToUniversal(Now);
    if DiffDays < 0 then
      Exit('Stopping...');
    DiffSec := Round(DiffDays * 24 * 60 * 60);
    if DiffSec >= 86400 then
      Result := Format('%d days', [DiffSec div 86400])
    else if DiffSec >= 3600 then
      Result := Format('%d hours', [DiffSec div 3600])
    else if DiffSec >= 60 then
      Result := Format('%d minutes', [DiffSec div 60])
    else
      Result := Format('%d seconds', [DiffSec]);
  end;

begin
  Mgr := FAgent.OllamaManager;
  if not Mgr.Active then
  begin
    DoOutput('error: OllamaManager is inactive, enable with "set active on"' + LineEnding, True);
    Exit;
  end;
  DoOutput('Fetching running models from ' + Mgr.BaseURL + ' ...' + LineEnding, False);
  PrevRefreshed := Mgr.OnModelsRefreshed;
  PrevError := Mgr.OnError;
  Mgr.OnModelsRefreshed := @HandleOllamaModelsRefreshed;
  Mgr.OnError := @HandleOllamaError;
  try
    FOllamaWaitModel := '';
    FOllamaOpDone := False;
    FOllamaOpKind := oekNone;
    FOllamaOpError := '';
    Mgr.RefreshModels;
    if not WaitOllamaOp(15000) then
    begin
      DoOutput('error: timeout waiting for running models' + LineEnding, True);
      Exit;
    end;
  finally
    Mgr.OnModelsRefreshed := PrevRefreshed;
    Mgr.OnError := PrevError;
  end;
  if FOllamaOpKind <> oekNone then
  begin
    DoOutput('error: ' + FOllamaOpError + LineEnding, True);
    Exit;
  end;
  if Mgr.RunningModels.Count = 0 then
  begin
    DoOutput('(no running models)' + LineEnding, False);
    Exit;
  end;
  // Columns match the ollama CLI: NAME ID SIZE PROCESSOR CONTEXT RUNNER UNTIL
  DoOutput(Format('%-20s %-15s %-10s %-20s %-10s %-12s %s', ['NAME', 'ID', 'SIZE', 'PROCESSOR', 'CONTEXT', 'RUNNER', 'UNTIL']) +
    LineEnding, False);
  for I := 0 to Mgr.RunningModels.Count - 1 do
  begin
    ModelName := Mgr.RunningModels[I];
    Json := Mgr.GetRunningModelJson(ModelName);
    ModelId := '-';
    SizeStr := 'unknown';
    Processor := 'unknown';
    Runner := '-';
    UntilText := 'unknown';
    CtxLen := 0;
    if Json <> '' then
    begin
      Data := nil;
      try
        try
          Data := GetJSON(Json);
        except
          Data := nil;
        end;
        if (Data <> nil) and (Data.JSONType = jtObject) then
        begin
          Obj := TJSONObject(Data);
          // Digest is "sha256:hex", CLI shows first 12 chars after the colon
          Digest := Obj.Get('digest', '');
          if Pos(':', Digest) > 0 then
            Digest := Copy(Digest, Pos(':', Digest) + 1, MaxInt);
          if Length(Digest) >= 12 then
            ModelId := Copy(Digest, 1, 12)
          else if Digest <> '' then
            ModelId := Digest;
          Size := Obj.Get('size', int64(0));
          SizeVram := Obj.Get('size_vram', int64(0));
          CtxLen := Obj.Get('context_length', int64(0));
          // Runner is present in newer Ollama versions, '-' otherwise
          Runner := Obj.Get('runner', '-');
          if Runner = '' then
            Runner := '-';
          if Size > 0 then
          begin
            SizeStr := HumanBytes2(Size);
            // CLI shows CPU/GPU order, not GPU/CPU
            if SizeVram <= 0 then
              Processor := '100% CPU'
            else if SizeVram >= Size then
              Processor := '100% GPU'
            else
            begin
              CpuPct := Round((Size - SizeVram) * 100 / Size);
              GpuPct := 100 - CpuPct;
              Processor := Format('%d%%/%d%% CPU/GPU', [CpuPct, GpuPct]);
            end;
          end;
          UntilText := HumanTime(Obj.Get('expires_at', ''));
        end;
      finally
        Data.Free;
      end;
    end;
    DoOutput(Format('%-20s %-15s %-10s %-20s %-10d %-12s %s', [ModelName, ModelId, SizeStr, Processor, CtxLen, Runner, UntilText]) +
      LineEnding, False);
  end;
end;

procedure TCustomTermManager.HandleOllamaShow(const AModel: string);
var
  Json, ErrMsg: string;
  Kind: TOllamaErrorKind;
  Data: TJSONData;
begin
  DoOutput('Fetching info for ' + AModel + ' ...' + LineEnding, False);
  Json := FAgent.OllamaManager.ShowModel(AModel, Kind, ErrMsg);
  if Kind <> oekNone then
  begin
    DoOutput('error: ' + ErrMsg + LineEnding, True);
    Exit;
  end;
  Data := nil;
  try
    try
      Data := GetJSON(Json);
    except
      Data := nil;
    end;
    if Data <> nil then
      DoOutput(Data.FormatJSON + LineEnding, False)
    else
      DoOutput(Json + LineEnding, False);
  finally
    Data.Free;
  end;
end;

procedure TCustomTermManager.HandleOllamaPull(const AModel: string);
var
  Mgr: TCustomOllamaManager;
  PrevProgress: TPullProgressEvent;
  PrevRefreshed: TModelsRefreshedEvent;
  PrevError: TOllamaErrorEvent;
  LastActivityTick: QWord;
  LastPct: integer;
begin
  Mgr := FAgent.OllamaManager;
  DoOutput('Pulling ' + AModel + ' from ' + Mgr.BaseURL + ' ...' + LineEnding, False);
  PrevProgress := Mgr.OnPullProgress;
  PrevRefreshed := Mgr.OnModelsRefreshed;
  PrevError := Mgr.OnError;
  Mgr.OnPullProgress := @HandleOllamaPullProgress;
  Mgr.OnModelsRefreshed := @HandleOllamaModelsRefreshed;
  Mgr.OnError := @HandleOllamaError;
  try
    FOllamaWaitModel := AModel;
    FOllamaOpDone := False;
    FOllamaOpKind := oekNone;
    FOllamaOpError := '';
    FOllamaPullPct := -1;
    FOllamaPullLastStep := -1;
    LastPct := -1;
    Mgr.PullModel(AModel);
    LastActivityTick := GetTickCount64;
    while not FOllamaOpDone do
    begin
      CheckSynchronize(50);
      // Reset inactivity clock whenever progress advances
      if FOllamaPullPct <> LastPct then
      begin
        LastPct := FOllamaPullPct;
        LastActivityTick := GetTickCount64;
      end;
      if GetTickCount64 - LastActivityTick >= QWord(60000) then
      begin
        DoOutput('error: no progress from server for 60 seconds' + LineEnding, True);
        Exit;
      end;
    end;
  finally
    Mgr.OnPullProgress := PrevProgress;
    Mgr.OnModelsRefreshed := PrevRefreshed;
    Mgr.OnError := PrevError;
  end;
  if FOllamaOpKind <> oekNone then
  begin
    DoOutput('error: ' + FOllamaOpError + LineEnding, True);
    Exit;
  end;
  DoOutput('pull complete: ' + AModel + LineEnding, False);
end;

procedure TCustomTermManager.HandleOllamaRm(const AModel: string);
var
  Mgr: TCustomOllamaManager;
  PrevError: TOllamaErrorEvent;
begin
  Mgr := FAgent.OllamaManager;
  DoOutput('Deleting ' + AModel + ' ...' + LineEnding, False);
  PrevError := Mgr.OnError;
  Mgr.OnError := @HandleOllamaError;
  try
    FOllamaWaitModel := '';
    FOllamaOpDone := False;
    FOllamaOpKind := oekNone;
    FOllamaOpError := '';
    Mgr.DeleteModel(AModel);
  finally
    Mgr.OnError := PrevError;
  end;
  if FOllamaOpKind <> oekNone then
  begin
    DoOutput('error: ' + FOllamaOpError + LineEnding, True);
    Exit;
  end;
  DoOutput('deleted: ' + AModel + LineEnding, False);
end;

procedure TCustomTermManager.HandleOllamaStop(const AModel: string);
var
  Kind: TOllamaErrorKind;
  ErrMsg: string;
begin
  DoOutput('Unloading ' + AModel + ' ...' + LineEnding, False);
  if FAgent.OllamaManager.UnloadModelSync(AModel, Kind, ErrMsg) then
    DoOutput('unloaded: ' + AModel + LineEnding, False)
  else
    DoOutput('error: ' + ErrMsg + LineEnding, True);
end;

procedure TCustomTermManager.HandleOllamaLoad(const AModel: string);
var
  Kind: TOllamaErrorKind;
  ErrMsg: string;
begin
  DoOutput('Loading ' + AModel + ' into memory ...' + LineEnding, False);
  if FAgent.OllamaManager.LoadModelSync(AModel, Kind, ErrMsg) then
    DoOutput('loaded: ' + AModel + LineEnding, False)
  else
    DoOutput('error: ' + ErrMsg + LineEnding, True);
end;

procedure TCustomTermManager.HandleOllamaUnload(const AModel: string);
begin
  HandleOllamaStop(AModel);
end;

procedure TCustomTermManager.HandleOllamaCopy(const ASource, ADest: string);
var
  Kind: TOllamaErrorKind;
  ErrMsg: string;
begin
  DoOutput('Copying ' + ASource + ' to ' + ADest + ' ...' + LineEnding, False);
  if FAgent.OllamaManager.CopyModel(ASource, ADest, Kind, ErrMsg) then
    DoOutput('copied: ' + ASource + ' -> ' + ADest + LineEnding, False)
  else
    DoOutput('error: ' + ErrMsg + LineEnding, True);
end;

procedure TCustomTermManager.HandleOllamaCreate(const AName, AFile: string);
var
  Kind: TOllamaErrorKind;
  ErrMsg, Content: string;
begin
  if not FileExists(AFile) then
  begin
    DoOutput('error: file not found: ' + AFile + LineEnding, True);
    Exit;
  end;
  DoOutput('Creating ' + AName + ' from ' + AFile + ' ...' + LineEnding, False);
  Content := ReadSmallTextFile(AFile);
  if Content = '' then
  begin
    DoOutput('error: cannot read ' + AFile + LineEnding, True);
    Exit;
  end;
  if FAgent.OllamaManager.CreateModel(AName, Content, Kind, ErrMsg) then
    DoOutput('created: ' + AName + LineEnding, False)
  else
    DoOutput('error: ' + ErrMsg + LineEnding, True);
end;

procedure TCustomTermManager.HandleOllamaVersion;
var
  Kind: TOllamaErrorKind;
  ErrMsg, Ver: string;
begin
  Ver := FAgent.OllamaManager.GetVersion(Kind, ErrMsg);
  if Kind <> oekNone then
    DoOutput('error: ' + ErrMsg + LineEnding, True)
  else
    DoOutput('ollama version: ' + Ver + LineEnding, False);
end;

procedure TCustomTermManager.HandleModelsCommand(const AArg: string);
var
  ListText, ErrMsg: string;
begin
  if not Assigned(FAgent) then
  begin
    DoOutput('error: no agent attached' + LineEnding, True);
    Exit;
  end;
  if not Assigned(FAgent.OllamaManager) then
  begin
    DoOutput('error: agent has no OllamaManager' + LineEnding, True);
    Exit;
  end;
  // "models" always refreshes from the server
  if LowerCase(Trim(AArg)) <> '' then
    DoOutput('tip: models always refreshes from ' + FAgent.OllamaManager.BaseURL + LineEnding, True);
  DoOutput('Querying ' + FAgent.OllamaManager.BaseURL + ' ...' + LineEnding, False);
  ListText := FormatModelsList(FAgent, ErrMsg);
  if ErrMsg <> '' then
    DoOutput('error: ' + ErrMsg + LineEnding, True)
  else
    DoOutput(ListText, False);
end;

procedure TCustomTermManager.PumpOutput(const AData: rawbytestring; AIsStderr: boolean; AFinal: boolean);
var
  Tmp, Pending: rawbytestring;
  I, J, TailLength, ProcessLength: SizeInt;
  B: byte;
begin
  if AIsStderr then
    Pending := FStdErrPending
  else
    Pending := FStdOutPending;

  Pending := Pending + AData;

  if Length(Pending) = 0 then
    Exit;

  TailLength := 0;

  if not AFinal then
  begin
    I := Length(Pending);

    while (I > 0) and ((Ord(Pending[I]) and $C0) = $80) and (TailLength < 3) do
    begin
      Inc(TailLength);
      Dec(I);
    end;

    if I > 0 then
    begin
      B := Ord(Pending[I]);

      if (B >= $C2) and (B <= $DF) then
        J := 2
      else if (B >= $E0) and (B <= $EF) then
        J := 3
      else if (B >= $F0) and (B <= $F4) then
        J := 4
      else
        J := 0;

      if (J > 0) and (Length(Pending) - I + 1 < J) then
        TailLength := Length(Pending) - I + 1
      else
        TailLength := 0;
    end
    else
      TailLength := 0;
  end;

  ProcessLength := Length(Pending) - TailLength;

  if ProcessLength <= 0 then
  begin
    if AIsStderr then
      FStdErrPending := Pending
    else
      FStdOutPending := Pending;
    Exit;
  end;

  Tmp := Copy(Pending, 1, ProcessLength);
  Delete(Pending, 1, ProcessLength);

  if AIsStderr then
    FStdErrPending := Pending
  else
    FStdOutPending := Pending;

  if not IsValidUTF8(Tmp) then
  begin
    {$IFDEF WINDOWS}
    SetCodePage(Tmp, GetOEMCP, False);
    {$ELSE}
    SetCodePage(Tmp, DefaultSystemCodePage, False);
    {$ENDIF}
    SetCodePage(Tmp, CP_UTF8, True);
  end;

  DoOutput(string(Tmp), AIsStderr);
end;

function TCustomTermManager.ExecuteCommand(const ACommand: string): integer;
var
  Process: TProcess;
  Buffer: TTermBuffer;
  BytesRead: longint;
  RawData: rawbytestring;
  StartTime: TDateTime;
  N: integer;
  DrivePath: string;
  CommandText: string;
  CommandName: string;
  P: integer;
  IsInteractive: boolean;
  HasMultipleLines: boolean;
  ShellFamily: TShellFamily;
  {$IFDEF WINDOWS}
  InHandle: THandle;
  InMode: DWORD = 0;
  InModeSaved: boolean;
  ScriptFileName: string;
  CwdFileName: string;
  CwdPath: string;
  ScriptData: RawByteString;
  ScriptStream: TFileStream;
  TempFileName: string;
  {$ENDIF}
begin
  Result := -1;
  Buffer := Default(TTermBuffer);
  if ACommand = '' then
    Exit;
  FStdOutPending := '';
  FStdErrPending := '';
  ShellFamily := DetectShellFamily(FShellExec);

  // Drive switch "d:", "d:\", "d:\path" must run in-process
  if (ShellFamily in [sfCmd, sfPowerShell]) and (Length(ACommand) >= 2) and (ACommand[2] = ':') and
    (ACommand[1] in ['a'..'z', 'A'..'Z']) and ((Length(ACommand) = 2) or (ACommand[3] in [PathDelim, '/'])) then
  begin
    if Length(ACommand) = 2 then
      DrivePath := UpCase(ACommand[1]) + ':\'
    else
      DrivePath := IncludeTrailingPathDelimiter(UpCase(ACommand[1]) + ':') + Copy(ACommand, 4, MaxInt);
    DrivePath := ExpandFileName(DrivePath);
    if DirectoryExists(DrivePath) then
    begin
      SetPath(DrivePath);
      Result := 0;
    end
    else
    begin
      DoOutput('Directory not found: ' + ACommand + LineEnding, True);
      Result := 1;
    end;
    Exit;
  end;

  // Detect commands that require direct console access
  CommandText := TrimLeft(ACommand);
  HasMultipleLines := (Pos(#10, CommandText) > 0) or (Pos(#13, CommandText) > 0);

  // Use only the first line when identifying the command
  P := Pos(#10, CommandText);
  if P > 0 then
    SetLength(CommandText, P - 1);
  CommandText := TrimRight(CommandText);

  if (CommandText <> '') and (CommandText[1] = '"') then
  begin
    P := Pos('"', Copy(CommandText, 2, MaxInt));
    if P > 0 then
      CommandName := Copy(CommandText, 2, P - 1)
    else
      CommandName := CommandText;
  end
  else
  begin
    P := Pos(' ', CommandText);
    if P = 0 then
      P := Pos(#9, CommandText);
    if P > 0 then
      CommandName := Copy(CommandText, 1, P - 1)
    else
      CommandName := CommandText;
  end;

  CommandName := LowerCase(ExtractFileName(StringReplace(CommandName, '\', '/', [rfReplaceAll])));

  // Multi-line scripts always capture output through the terminal
  IsInteractive := not HasMultipleLines and (Pos('|' + CommandName + '|', INTERACTIVE_COMMANDS) > 0);

  RawData := '';
  {$IFDEF WINDOWS}
  ScriptFileName := string.Empty;
  CwdFileName := string.Empty;
  TempFileName := string.Empty;
  {$ENDIF}
  Process := TProcess.Create(nil);
  {$IFDEF WINDOWS}
  InModeSaved := False;
  {$ENDIF}
  try
    Process.Executable := FShellExec;
    {$IFDEF WINDOWS}
    case ShellFamily of
      sfCmd:
      begin
        Process.Parameters.Add('/c');

        if HasMultipleLines then
        begin
          // Create temporary files for the batch script and working directory
          TempFileName := SysUtils.GetTempFileName;
          ScriptFileName := ChangeFileExt(TempFileName, '.cmd');
          CwdFileName := SysUtils.GetTempFileName;

          // Create the temporary files before renaming or using them
          ScriptStream := TFileStream.Create(TempFileName, fmCreate);
          ScriptStream.Free;

          ScriptStream := TFileStream.Create(CwdFileName, fmCreate);
          ScriptStream.Free;

          if not RenameFile(TempFileName, ScriptFileName) then
            raise Exception.Create('Cannot create temporary batch file');

          // Append the final working directory to a separate file
          ScriptData := rawbytestring(PrepareCmdBatchScript(ACommand) + LineEnding + '@echo %CD%> "' + CwdFileName + '"' + LineEnding);

          ScriptStream := TFileStream.Create(ScriptFileName, fmCreate);
          try
            if Length(ScriptData) > 0 then
              ScriptStream.WriteBuffer(ScriptData[1], Length(ScriptData));
          finally
            ScriptStream.Free;
          end;

          Process.Parameters.Add('"' + ScriptFileName + '"');
        end
        else
          Process.Parameters.Add(ACommand);
      end;

      sfPowerShell:
      begin
        if HasMultipleLines then
        begin
          // Create temporary files for the PowerShell script and working directory
          TempFileName := SysUtils.GetTempFileName;
          ScriptFileName := ChangeFileExt(TempFileName, '.ps1');
          CwdFileName := SysUtils.GetTempFileName;

          ScriptStream := TFileStream.Create(TempFileName, fmCreate);
          ScriptStream.Free;

          ScriptStream := TFileStream.Create(CwdFileName, fmCreate);
          ScriptStream.Free;

          if not RenameFile(TempFileName, ScriptFileName) then
            raise Exception.Create('Cannot create temporary PowerShell script');

          // Configure UTF-8 output and save the final working directory
          ScriptData := UTF8Encode(UTF8Decode('$ProgressPreference = ''SilentlyContinue''' +
            LineEnding + '$utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false' + LineEnding +
            '[Console]::OutputEncoding = $utf8' + LineEnding + '$OutputEncoding = $utf8' +
            LineEnding + ACommand + LineEnding + '[IO.File]::WriteAllText(''' +
            StringReplace(CwdFileName, '''', '''''', [rfReplaceAll]) + ''', (Get-Location).Path, $utf8)' + LineEnding));

          ScriptStream := TFileStream.Create(ScriptFileName, fmCreate);
          try
            // Write UTF-8 BOM for Windows PowerShell 5.1
            ScriptStream.WriteByte($EF);
            ScriptStream.WriteByte($BB);
            ScriptStream.WriteByte($BF);

            if Length(ScriptData) > 0 then
              ScriptStream.WriteBuffer(ScriptData[1], Length(ScriptData));
          finally
            ScriptStream.Free;
          end;

          Process.Parameters.Add('-NoProfile');
          Process.Parameters.Add('-OutputFormat');
          Process.Parameters.Add('Text');
          Process.Parameters.Add('-ExecutionPolicy');
          Process.Parameters.Add('Bypass');
          Process.Parameters.Add('-File');
          Process.Parameters.Add(ScriptFileName);
        end
        else
        begin
          Process.Parameters.Add('-NoProfile');
          Process.Parameters.Add('-OutputFormat');
          Process.Parameters.Add('Text');
          Process.Parameters.Add('-ExecutionPolicy');
          Process.Parameters.Add('Bypass');
          Process.Parameters.Add('-EncodedCommand');
          Process.Parameters.Add(EncodePowerShellCommand('$ProgressPreference = ''SilentlyContinue''; ' +
            '$utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false; ' +
            '[Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8; ' + ACommand));
        end;
      end;

      sfUnix:
      begin
        Process.Parameters.Add('-c');
        Process.Parameters.Add(ACommand);
      end;

      else
        // Unknown shells receive the command without shell-specific wrappers
        Process.Parameters.Add(ACommand);
    end;
    {$ELSE}
    if ShellFamily = sfUnix then
    begin
      Process.Parameters.Add('-c');
      Process.Parameters.Add(ACommand);
    end
    else
      Process.Parameters.Add(ACommand);
    {$ENDIF}

    if IsInteractive then
    begin
      Process.Options := [];
      {$IFDEF WINDOWS}
      // Restore standard console input mode for the interactive process
      InHandle := GetStdHandle(STD_INPUT_HANDLE);
      InModeSaved := GetConsoleMode(InHandle, InMode);
      if InModeSaved then
        SetConsoleMode(InHandle, InMode or ENABLE_ECHO_INPUT or ENABLE_LINE_INPUT or ENABLE_PROCESSED_INPUT);
      {$ENDIF}
    end
    else
      Process.Options := [poUsePipes, poNoConsole];

    Process.CurrentDirectory := GetEffectivePath;
    Process.Execute;
    StartTime := Now;

    if IsInteractive then
    begin
      // Wait for the interactive process without capturing its console output
      while Process.Running do
      begin
        if (FCommandTimeout > 0) and (MilliSecondsBetween(Now, StartTime) >= FCommandTimeout) then
        begin
          Process.Terminate(1);
          DoOutput(LineEnding + '[timeout]' + LineEnding, True);
          Break;
        end;
        Sleep(10);
      end;

      Result := Process.ExitStatus;
      Exit;
    end;

    while Process.Running do
    begin
      if (FCommandTimeout > 0) and (MilliSecondsBetween(Now, StartTime) >= FCommandTimeout) then
      begin
        Process.Terminate(1);
        DoOutput(LineEnding + '[timeout]' + LineEnding, True);
        Break;
      end;
      {$IFDEF WINDOWS}
      if CheckAndConsumeCancel then
      begin
        Process.Terminate(1);
        DoOutput(LineEnding + '^C (interrupted)' + LineEnding, True);
        Break;
      end;
      {$ENDIF}

      if Process.Output.NumBytesAvailable > 0 then
      begin
        N := Process.Output.NumBytesAvailable;
        if N > SizeOf(Buffer) then
          N := SizeOf(Buffer);
        BytesRead := Process.Output.Read(Buffer[0], N);
        if BytesRead > 0 then
        begin
          SetLength(RawData, BytesRead);
          Move(Buffer[0], RawData[1], BytesRead);
          PumpOutput(RawData, False);
        end;
      end;

      if Process.Stderr.NumBytesAvailable > 0 then
      begin
        N := Process.Stderr.NumBytesAvailable;
        if N > SizeOf(Buffer) then
          N := SizeOf(Buffer);
        BytesRead := Process.Stderr.Read(Buffer[0], N);
        if BytesRead > 0 then
        begin
          SetLength(RawData, BytesRead);
          Move(Buffer[0], RawData[1], BytesRead);
          PumpOutput(RawData, True);
        end;
      end;

      Sleep(10);
    end;

    // Drain remaining output after termination
    while Process.Output.NumBytesAvailable > 0 do
    begin
      N := Process.Output.NumBytesAvailable;
      if N > SizeOf(Buffer) then
        N := SizeOf(Buffer);
      BytesRead := Process.Output.Read(Buffer[0], N);
      if BytesRead > 0 then
      begin
        SetLength(RawData, BytesRead);
        Move(Buffer[0], RawData[1], BytesRead);
        PumpOutput(RawData, False);
      end;
    end;
    while Process.Stderr.NumBytesAvailable > 0 do
    begin
      N := Process.Stderr.NumBytesAvailable;
      if N > SizeOf(Buffer) then
        N := SizeOf(Buffer);
      BytesRead := Process.Stderr.Read(Buffer[0], N);
      if BytesRead > 0 then
      begin
        SetLength(RawData, BytesRead);
        Move(Buffer[0], RawData[1], BytesRead);
        PumpOutput(RawData, True);
      end;
    end;

    PumpOutput('', False, True);
    PumpOutput('', True, True);

    // Restore the working directory after a multi-line batch script
    {$IFDEF WINDOWS}
    if HasMultipleLines and (CwdFileName <> '') and FileExists(CwdFileName) then
    begin
      CwdPath := Trim(ReadSmallTextFile(CwdFileName));
      if DirectoryExists(CwdPath) then
        SetPath(CwdPath);
    end;
    {$ENDIF}

    Result := Process.ExitStatus;
  finally
    {$IFDEF WINDOWS}
      if IsInteractive and InModeSaved then
        SetConsoleMode(InHandle, InMode);
    {$ENDIF}
    Process.Free;
    {$IFDEF WINDOWS}
    // Remove temporary files after execution
    if (ScriptFileName <> '') and FileExists(ScriptFileName) then
      SysUtils.DeleteFile(ScriptFileName);
    if (TempFileName <> '') and FileExists(TempFileName) then
      SysUtils.DeleteFile(TempFileName);
    if (CwdFileName <> '') and FileExists(CwdFileName) then
      SysUtils.DeleteFile(CwdFileName);
    {$ENDIF}
  end;
end;

function TCustomTermManager.ExecuteCommandCapture(const ACommand: string; out AExitCode: integer; ATimeoutMs: integer): string;
var
  Process: TProcess;
  Buffer: TTermBuffer;
  RawData, Captured, Tmp: rawbytestring;
  StartTime: TDateTime;
  EffectiveTimeout: integer;
  HitLimit: boolean;
  ShellFamily: TShellFamily;

// Appends bytes to Captured and enforces MaxCaptureBytes limit
  procedure AppendAndCheck(const AData: rawbytestring);
  begin
    if HitLimit or (Length(AData) = 0) then
      Exit;
    Captured := Captured + AData;
    if Length(Captured) > FMaxCaptureBytes then
    begin
      SetLength(Captured, FMaxCaptureBytes);
      Captured := Captured + #13#10 + '[output truncated at ' + IntToStr(FMaxCaptureBytes) + ' bytes]' + #13#10;
      HitLimit := True;
    end;
  end;

  // Reads up to AAvailable bytes from stream into Captured
  function ReadAvailable(AStream: TStream; AAvailable: longint): longint;
  var
    M: integer;
  begin
    Result := 0;
    if HitLimit or (AAvailable <= 0) then
      Exit;
    M := AAvailable;
    if M > SizeOf(Buffer) then
      M := SizeOf(Buffer);
    Result := AStream.Read(Buffer[0], M);
    if Result > 0 then
    begin
      SetLength(RawData, Result);
      Move(Buffer[0], RawData[1], Result);
      AppendAndCheck(RawData);
    end;
  end;

begin
  Result := '';
  RawData := '';
  AExitCode := -1;
  Buffer := Default(TTermBuffer);
  if ACommand = '' then
    Exit;
  if ATimeoutMs < 0 then
    EffectiveTimeout := FCommandTimeout
  else
    EffectiveTimeout := ATimeoutMs;
  Captured := '';
  HitLimit := False;
  Process := TProcess.Create(nil);
  try
    Process.Executable := FShellExec;
    ShellFamily := DetectShellFamily(FShellExec);

    {$IFDEF WINDOWS}
    case ShellFamily of
      sfCmd:
      begin
        Process.Parameters.Add('/c');
        Process.Parameters.Add(ACommand);
      end;

      sfPowerShell:
      begin
        Process.Parameters.Add('-NoProfile');
        Process.Parameters.Add('-ExecutionPolicy');
        Process.Parameters.Add('Bypass');
        Process.Parameters.Add('-EncodedCommand');
        Process.Parameters.Add(EncodePowerShellCommand(
          '$utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false; ' +
          '[Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8; ' +
          ACommand));
      end;

      sfUnix:
      begin
        Process.Parameters.Add('-c');
        Process.Parameters.Add(ACommand);
      end;

      else
        Process.Parameters.Add(ACommand);
    end;
    {$ELSE}
    if ShellFamily = sfUnix then
    begin
      Process.Parameters.Add('-c');
      Process.Parameters.Add(ACommand);
    end
    else
      Process.Parameters.Add(ACommand);
    {$ENDIF}
    Process.Options := [poUsePipes, poNoConsole];
    Process.CurrentDirectory := GetEffectivePath;
    Process.Execute;
    StartTime := Now;

    while Process.Running do
    begin
      if HitLimit then
      begin
        Process.Terminate(1);
        Break;
      end;
      if (EffectiveTimeout > 0) and (MilliSecondsBetween(Now, StartTime) >= EffectiveTimeout) then
      begin
        Process.Terminate(1);
        AppendAndCheck(#13#10 + '[timeout after ' + IntToStr(EffectiveTimeout) + ' ms]' + #13#10);
        Break;
      end;
      ReadAvailable(Process.Output, Process.Output.NumBytesAvailable);
      ReadAvailable(Process.Stderr, Process.Stderr.NumBytesAvailable);
      Sleep(10);
    end;

    // Drain remaining output after termination
    while (not HitLimit) and (Process.Output.NumBytesAvailable > 0) do
      ReadAvailable(Process.Output, Process.Output.NumBytesAvailable);
    while (not HitLimit) and (Process.Stderr.NumBytesAvailable > 0) do
      ReadAvailable(Process.Stderr, Process.Stderr.NumBytesAvailable);

    AExitCode := Process.ExitStatus;

    Tmp := Captured;

    if not IsValidUTF8(Tmp) then
    begin
      {$IFDEF WINDOWS}
      SetCodePage(Tmp, GetOEMCP, False);
      {$ELSE}
      SetCodePage(Tmp, DefaultSystemCodePage, False);
      {$ENDIF}
      SetCodePage(Tmp, CP_UTF8, True);
    end;

    Result := string(Tmp);
  finally
    Process.Free;
  end;
end;

procedure TCustomTermManager.AddToHistory(const ALine: string);
var
  Tagged: rawbytestring;
begin
  if ALine = '' then
    Exit;
  // Skip meta and chat control commands such as exit, quit, cls
  if IsChatControlCommand(ALine) then
    Exit;
  // Tag as UTF-8 without recoding so SetCodePage works on RawByteString
  Tagged := ALine;
  SetCodePage(Tagged, CP_UTF8, False);
  if (FHistory.Count > 0) and (FHistory[FHistory.Count - 1] = Tagged) then
    Exit;
  FHistory.Add(Tagged);
  while FHistory.Count > FHistoryMax do
    FHistory.Delete(0);

  if Assigned(FAgent) and Assigned(FAgent.ActiveChat) then
  begin
    FAgent.ActiveChat.TerminalHistory.Assign(FHistory);
    FAgent.ActiveChat.MarkSessionActive;
  end;
end;

procedure TCustomTermManager.Run;
var
  Line, Payload: string;
  Kind: TTermInputKind;
  UseStartupPrompt: boolean;
  Allow: boolean;
  CancelledShown: boolean;
  WaitShown: boolean;
  StartTick: QWord;
  Mark: TTerminalOutputMark;
  {$IFDEF WINDOWS}
  InHandle: THandle;
  InMode: DWORD = 0;
  InModeSaved: boolean;
  {$ENDIF}
begin
  RestoreActiveChat;

  {$IFDEF WINDOWS}
  // Force UTF-8 everywhere so OEM->UTF-8 conversion is consistent
  DefaultSystemCodePage := CP_UTF8;
  SetMultiByteConversionCodePage(CP_UTF8);
  SetConsoleCP(CP_UTF8);
  SetConsoleOutputCP(CP_UTF8);
  SetTextCodePage(Output, CP_UTF8);
  SetTextCodePage(ErrOutput, CP_UTF8);
  // Disable console echo and line editing, we draw input ourselves
  InHandle := GetStdHandle(STD_INPUT_HANDLE);
  InModeSaved := GetConsoleMode(InHandle, InMode);
  if InModeSaved then
    SetConsoleMode(InHandle, InMode and not (ENABLE_ECHO_INPUT or ENABLE_LINE_INPUT or ENABLE_PROCESSED_INPUT));
  {$ENDIF}

  // Show the welcome banner only when the active chat is completely empty
  if FWelcome <> '' then
  begin
    if not Assigned(FAgent) or not Assigned(FAgent.ActiveChat) or ((FAgent.ActiveChat.History = string.Empty) and
      (FAgent.ActiveChat.TerminalOutput = string.Empty)) then
    begin
      SetColor(tcWelcome);
      DoOutput(FWelcome + LineEnding, False);
      SetColor(tcDefault);
    end;
  end;

  // Start with explicit default color so prompt and banner match scheme
  SetColor(tcDefault);
  UseStartupPrompt := FStartupPrompt <> string.Empty;

  FRunning := True;
  FLastExitCode := 0;
  try
    while FRunning do
    begin
      if UseStartupPrompt then
      begin
        // Refresh context information before displaying the startup prompt
        if Assigned(FAgent) then
          FAgent.RefreshContextInfo(False);

        Line := '?' + FStartupPrompt;
        FStartupPrompt := string.Empty;
        UseStartupPrompt := False;

        // Display and record the initial agent request
        WriteLine(GetPromptText + Line, False);
        AddToHistory(Line);

        if Assigned(FAgent) and Assigned(FAgent.ActiveChat) then
          FPendingOutputStart := Length(FAgent.ActiveChat.TerminalOutput);

        AppendChatOutput(GetPromptText + Line + LineEnding);
      end
      else
        Line := ReadLine;
      if not FRunning then
        Break;
      Kind := ClassifyLine(Line, Payload);
      if Kind = tikEmpty then
        Continue;
      Allow := True;
      DoRoute(Line, Payload, Kind, Allow);
      if not Allow then
        Continue;

      FCurrentOutputMark := False;

      // Store the accepted input in the active chat output stack
      if Assigned(FAgent) and Assigned(FAgent.ActiveChat) and (FPendingOutputStart >= 0) and (Kind <> tikEmpty) then
      begin
        Mark := Default(TTerminalOutputMark);
        Mark.OutputStart := FPendingOutputStart;
        Mark.InputKind := Ord(Kind);
        Mark.ShellLogCount := 0;
        Mark.ScreenRow := FPendingScreenRow;
        Mark.ScreenCol := FPendingScreenCol;
        FAgent.ActiveChat.AddOutputMark(Mark);
        FCurrentOutputMark := True;
      end;

      FPendingOutputStart := -1;
      FPendingScreenRow := -1;
      FPendingScreenCol := -1;

      case Kind of
        tikBuiltin:
        begin
          FCaptureCommand := Payload;
          FCaptureOutput := '';
          FCaptureError := False;
          FCapturing := True;
          try
            HandleBuiltin(Payload);
          finally
            FCapturing := False;
            // Meta commands like cls and exit are not relevant to the model
            if not IsMetaCommand(FCaptureCommand) then
              RecordShellOperation(FCaptureCommand, FCaptureOutput, FCaptureError);
          end;
        end;
        tikCommand:
        begin
          FCaptureCommand := Payload;
          FCaptureOutput := '';
          FCaptureError := False;
          FCapturing := True;
          try
            FLastExitCode := ExecuteCommand(Payload);
          finally
            FCapturing := False;
            RecordShellOperation(FCaptureCommand, FCaptureOutput, FCaptureError);

            // Leave one empty line between command output and the next prompt
            if not FLastCharWasNewLine then
              WriteLine('', False);
            WriteLine('', False);
          end;
        end;
        tikAgent:
          if Assigned(FAgent) then
          begin
            // Pass shell history to the agent as prelude context
            if FShellHistory.Enabled and (FShellLog.Count > 0) then
            begin
              if FAgent.ContextPrelude <> '' then
                FAgent.ContextPrelude := FAgent.ContextPrelude + #10#10 + BuildShellContext
              else
                FAgent.ContextPrelude := BuildShellContext;
              if FShellHistory.ClearOnAgentRun then
              begin
                FShellLog.Clear;
                if Assigned(FAgent.ActiveChat) then
                begin
                  FAgent.ActiveChat.ShellLog.Clear;
                  FAgent.ActiveChat.MarkSessionActive;
                end;
              end;
            end;
            // Save user handlers, install our own for the duration of the run
            FPrevAgentOnChunk := FAgent.OnChunk;
            FPrevAgentOnThinking := FAgent.OnThinking;
            FPrevAgentOnToolCall := FAgent.OnToolCall;
            FPrevAgentOnToolResult := FAgent.OnToolResult;
            FPrevAgentOnFinish := FAgent.OnFinish;
            FPrevAgentOnExecCommand := FAgent.OnExecCommand;
            FPrevAgentOnAskUser := FAgent.OnAskUser;
            FPrevAgentOnLog := FAgent.OnLog;
            FPrevAgentOnContextUsage := FAgent.OnContextUsage;
            FAgent.OnChunk := @HandleAgentChunk;
            FAgent.OnThinking := @HandleAgentThinking;
            FAgent.OnToolCall := @HandleAgentToolCall;
            FAgent.OnToolResult := @HandleAgentToolResult;
            FAgent.OnFinish := @HandleAgentFinish;
            FAgent.OnExecCommand := @HandleAgentExecCommand;
            FAgent.OnAskUser := @HandleAgentAskUser;
            FAgent.OnContextUsage := @HandleAgentContextUsage;
            try
              FFirstChunkSeen := False;
              FAgent.RunAsync(Payload);
              // Pump events and watch for Esc so user can cancel
              StartTick := GetTickCount64;
              WaitShown := False;
              CancelledShown := False;
              while not FAgent.Done do
              begin
                CheckSynchronize(50);
                // After WaitCheckDelayMs of silence show one hint, distinguishing
                // reachable server from unreachable with a plain TCP check
                if (not WaitShown) and (not FFirstChunkSeen) and (FWaitCheckDelayMs > 0) and
                  (GetTickCount64 - StartTick >= QWord(FWaitCheckDelayMs)) then
                begin
                  if Assigned(FAgent.OllamaManager) and not FAgent.OllamaManager.CheckServerReachableQuick(500) then
                    WriteLine(string(FWaitServerDownHint), True)
                  else
                    WriteLine(string(FWaitSlowHint), True);
                  WaitShown := True;
                end;
                if not CancelledShown and CheckAndConsumeCancel then
                begin
                  FAgent.Cancel;
                  WriteLine('^C (cancelling...)', True);
                  CancelledShown := True;
                end;
              end;
              CheckSynchronize(0);
              // Ensure prompt starts on a fresh line even if finish was missed
              if not FLastCharWasNewLine then
                WriteLine('', False);
            finally
              // Restore user handlers so designer state is preserved
              FAgent.OnChunk := FPrevAgentOnChunk;
              FAgent.OnThinking := FPrevAgentOnThinking;
              FAgent.OnToolCall := FPrevAgentOnToolCall;
              FAgent.OnToolResult := FPrevAgentOnToolResult;
              FAgent.OnFinish := FPrevAgentOnFinish;
              FAgent.OnExecCommand := FPrevAgentOnExecCommand;
              FAgent.OnAskUser := FPrevAgentOnAskUser;
              FAgent.OnLog := FPrevAgentOnLog;
              FAgent.OnContextUsage := FPrevAgentOnContextUsage;
              FPrevAgentOnChunk := nil;
              FPrevAgentOnThinking := nil;
              FPrevAgentOnToolCall := nil;
              FPrevAgentOnToolResult := nil;
              FPrevAgentOnFinish := nil;
              FPrevAgentOnExecCommand := nil;
              FPrevAgentOnAskUser := nil;
              FPrevAgentOnContextUsage := nil;
              FPrevAgentOnLog := nil;
              FInThinking := False;
              SetColor(tcDefault);
            end;
          end
          else
            DoAgentExecute(Payload);
        else
          ;
      end;

      FCurrentOutputMark := False;
    end;
  finally
    {$IFDEF WINDOWS}
    if InModeSaved then
      SetConsoleMode(InHandle, InMode)
    {$ENDIF}
    ;
  end;
  DoExit(FLastExitCode);
end;

procedure TCustomTermManager.Stop;
begin
  // Stop the active agent before leaving the console loop
  if Assigned(FAgent) and not FAgent.Done then
    FAgent.Cancel;

  FRunning := False;
end;

{$IFDEF WINDOWS}

// Maps palette color to Windows foreground attribute bits
function ColorToAttr(AColor: TConsoleColor): word;
const
  MAP: array[TConsoleColor] of word = (
    // Standard colors, 0 to 7
    0,                                                     // ccBlack
    FOREGROUND_RED,                                        // ccRed
    FOREGROUND_GREEN,                                      // ccGreen
    FOREGROUND_RED or FOREGROUND_GREEN,                    // ccYellow
    FOREGROUND_BLUE,                                       // ccBlue
    FOREGROUND_RED or FOREGROUND_BLUE,                     // ccMagenta
    FOREGROUND_GREEN or FOREGROUND_BLUE,                   // ccCyan
    FOREGROUND_RED or FOREGROUND_GREEN or FOREGROUND_BLUE, // ccLightGray
    // Bright colors, 8 to 15
    FOREGROUND_INTENSITY,                                  // ccDarkGray
    FOREGROUND_RED or FOREGROUND_INTENSITY,                // ccLightRed
    FOREGROUND_GREEN or FOREGROUND_INTENSITY,              // ccLightGreen
    FOREGROUND_RED or FOREGROUND_GREEN or FOREGROUND_INTENSITY, // ccLightYellow
    FOREGROUND_BLUE or FOREGROUND_INTENSITY,               // ccLightBlue
    FOREGROUND_RED or FOREGROUND_BLUE or FOREGROUND_INTENSITY, // ccLightMagenta
    FOREGROUND_GREEN or FOREGROUND_BLUE or FOREGROUND_INTENSITY, // ccLightCyan
    FOREGROUND_RED or FOREGROUND_GREEN or FOREGROUND_BLUE or FOREGROUND_INTENSITY // ccWhite
    );
begin
  Result := MAP[AColor];
end;

// Applies console text attribute directly, ignored for redirected handles
procedure SetConsoleColor(AAttr: word);
var
  Handle: THandle;
begin
  Handle := GetStdHandle(STD_OUTPUT_HANDLE);
  SetConsoleTextAttribute(Handle, AAttr);
end;

procedure TCustomTermManager.SetColor(AColor: TTermColor);
var
  Attr: word;
  Info: TConsoleScreenBufferInfo;

// Combines background and foreground of a pair into a single attribute
  function PairAttr(const APair: TConsoleColorPair): word;
  begin
    Result := (ColorToAttr(APair.Background) shl 4) or ColorToAttr(APair.Foreground);
  end;

begin
  // Store color changes as control markers for chat history replay
  AppendChatOutput(#2 + Chr(Ord(AColor)));
  Info := Default(TConsoleScreenBufferInfo);

  if not FColorOutput then
    Exit;

  // Preserve the original console background before applying prompt colors
  if (AColor = tcPromptInput) and not FDefaultConsoleAttrCaptured then
    if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info) then
    begin
      FDefaultConsoleAttr := Info.wAttributes;
      FDefaultConsoleAttrCaptured := True;
    end;

  case AColor of
    tcDim: Attr := ColorToAttr(FColors.ThinkingText);
    tcWelcome: Attr := PairAttr(FColors.WelcomeBadge);
    tcThinkingBadge: Attr := PairAttr(FColors.ThinkingBadge);
    tcToolBadge: Attr := PairAttr(FColors.ToolBadge);
    tcErrorBadge: Attr := PairAttr(FColors.ErrorBadge);
    tcWarnBadge: Attr := PairAttr(FColors.WarnBadge);
    tcPromptInput: Attr := PairAttr(FColors.PromptInput);
    tcLog: Attr := PairAttr(FColors.Log);
    tcMarkdownMarker: Attr := ColorToAttr(FColors.Markdown.Marker);
    tcMarkdownBold: Attr := ColorToAttr(FColors.Markdown.Bold);
    tcMarkdownItalic: Attr := ColorToAttr(FColors.Markdown.Italic);
    tcMarkdownStrike: Attr := ColorToAttr(FColors.Markdown.Strikethrough);
    tcMarkdownCode: Attr := ColorToAttr(FColors.Markdown.InlineCode);
    tcMarkdownHighlight: Attr := ColorToAttr(FColors.Markdown.Highlight);
    tcMarkdownHeading: Attr := ColorToAttr(FColors.Markdown.Heading);
    tcMarkdownQuote: Attr := ColorToAttr(FColors.Markdown.Quote);
    tcMarkdownList: Attr := ColorToAttr(FColors.Markdown.ListMarker);
    tcMarkdownFencedCode: Attr := ColorToAttr(FColors.Markdown.FencedCode);
    tcDefault:
      if FDefaultConsoleAttrCaptured then
        Attr := (FDefaultConsoleAttr and $F0) or ColorToAttr(FColors.DefaultText)
      else
        Attr := ColorToAttr(FColors.DefaultText);
    else
      Attr := ColorToAttr(FColors.DefaultText);
  end;
  SetConsoleColor(Attr);
end;

procedure TCustomTermManager.ReplayChatOutput(const AText: string);
var
  I, J, ColorValue: integer;
  {$IFDEF WINDOWS}
  MarkIndex: integer;
  Mark: TTerminalOutputMark;
  Info: TConsoleScreenBufferInfo;
  {$ENDIF}

  {$IFDEF WINDOWS}
  // Updates saved screen positions when replay reaches an operation boundary
  procedure CaptureOutputMarks(APos: SizeInt);
  begin
    if not Assigned(FAgent) or not Assigned(FAgent.ActiveChat) then
      Exit;

    while MarkIndex < Length(FAgent.ActiveChat.OutputMarks) do
    begin
      Mark := FAgent.ActiveChat.OutputMarks[MarkIndex];

      if Mark.OutputStart > APos then
        Break;

      if Mark.OutputStart = APos then
      begin
        Info := Default(TConsoleScreenBufferInfo);
        if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info) then
          FAgent.ActiveChat.SetOutputMarkScreenPosition(
            MarkIndex, Info.dwCursorPosition.Y, Info.dwCursorPosition.X)
        else
          FAgent.ActiveChat.SetOutputMarkScreenPosition(MarkIndex, -1, -1);
      end;

      Inc(MarkIndex);
    end;
  end;
  {$ENDIF}
begin
  {$IFDEF WINDOWS}
  I := 1;
  MarkIndex := 0;

  while I <= Length(AText) do
  begin
    CaptureOutputMarks(I - 1);

    if (AText[I] = #2) and (I < Length(AText)) then
    begin
      ColorValue := Ord(AText[I + 1]);
      if ColorValue <= Ord(High(TTermColor)) then
        SetColor(TTermColor(ColorValue));

      Inc(I, 2);
    end
    else
    begin
      J := I;

      // Stop before the next color marker or operation boundary
      while J <= Length(AText) do
      begin
        if AText[J] = #2 then
          Break;

        if Assigned(FAgent) and Assigned(FAgent.ActiveChat) and
          (MarkIndex < Length(FAgent.ActiveChat.OutputMarks)) and
          (FAgent.ActiveChat.OutputMarks[MarkIndex].OutputStart = J - 1) then
          Break;

        Inc(J);
      end;

      if J > I then
      begin
        WriteText(Copy(AText, I, J - I), False);
        I := J;
      end;
    end;
  end;

  CaptureOutputMarks(Length(AText));
  {$ELSE}
  I := 1;
  while I <= Length(AText) do
  begin
    if (AText[I] = #2) and (I < Length(AText)) then
    begin
      ColorValue := Ord(AText[I + 1]);
      if ColorValue <= Ord(High(TTermColor)) then
        SetColor(TTermColor(ColorValue));

      Inc(I, 2);
    end
    else
    begin
      J := I;
      while (J <= Length(AText)) and (AText[J] <> #2) do
        Inc(J);

      WriteText(Copy(AText, I, J - I), False);
      I := J;
    end;
  end;
  {$ENDIF}

  SetColor(tcDefault);
end;

// Writes UTF-8 bytes directly to handle bypassing codepage conversion
procedure WriteUtf8ToHandle(AHandle: THandle; const ABytes: rawbytestring);
const
  ENABLE_VIRTUAL_TERMINAL_PROCESSING = $0004;
var
  Mode: DWORD;
  Written: DWORD;
  Wide: unicodestring;
  Ok: boolean;
begin
  if Length(ABytes) = 0 then
    Exit;

  Mode := 0;
  Written := 0;
  Ok := False;

  if (AHandle <> INVALID_HANDLE_VALUE) and GetConsoleMode(AHandle, Mode) then
  begin
    // Enable ANSI escape sequence processing when supported
    if (Mode and ENABLE_VIRTUAL_TERMINAL_PROCESSING) = 0 then
      SetConsoleMode(AHandle, Mode or ENABLE_VIRTUAL_TERMINAL_PROCESSING);

    Wide := UTF8Decode(ABytes);
    if Length(Wide) > 0 then
      Ok := WriteConsoleW(AHandle, pwidechar(Wide), Length(Wide), Written, nil);
  end;

  // Fallback when WriteConsoleW fails or handle is not a console
  if not Ok then
    WriteFile(AHandle, ABytes[1], Length(ABytes), Written, nil);
end;

// Writes text to stdout as UTF-8, bypassing Output codepage
procedure ConWriteUtf8(const AText: string);
begin
  WriteUtf8ToHandle(GetStdHandle(STD_OUTPUT_HANDLE), UTF8Encode(AText));
end;

procedure ConGotoXY(X, Y: integer);
var
  Coord: TCoord;
begin
  Coord.X := X - 1;
  Coord.Y := Y - 1;
  SetConsoleCursorPosition(GetStdHandle(STD_OUTPUT_HANDLE), Coord);
end;

function ConWhereY: integer;
var
  Info: TConsoleScreenBufferInfo;
begin
  Result := 1;
  Info := Default(TConsoleScreenBufferInfo);
  if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info) then
    Result := Info.dwCursorPosition.Y + 1;
end;

procedure ConClearLineFromCursor;
var
  Info: TConsoleScreenBufferInfo;
  Count: DWORD;
  Written: DWORD;
begin
  Written := 0;
  Info := Default(TConsoleScreenBufferInfo);
  if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info) then
  begin
    Count := Info.dwSize.X - Info.dwCursorPosition.X;
    if Count > 0 then
    begin
      FillConsoleOutputCharacter(GetStdHandle(STD_OUTPUT_HANDLE), ' ', Count,
        Info.dwCursorPosition, Written);
      FillConsoleOutputAttribute(GetStdHandle(STD_OUTPUT_HANDLE), Info.wAttributes,
        Count, Info.dwCursorPosition, Written);
    end;
  end;
end;

procedure ClearScreen;
var
  Info: TConsoleScreenBufferInfo;
  Coord: TCoord;
  Size: DWORD;
  Written: DWORD;
begin
  Written := 0;
  Info := Default(TConsoleScreenBufferInfo);
  if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info) then
  begin
    Coord.X := 0;
    Coord.Y := 0;
    Size := Info.dwSize.X * Info.dwSize.Y;
    FillConsoleOutputCharacter(GetStdHandle(STD_OUTPUT_HANDLE), ' ', Size,
      Coord, Written);
    FillConsoleOutputAttribute(GetStdHandle(STD_OUTPUT_HANDLE), Info.wAttributes,
      Size, Coord, Written);
    SetConsoleCursorPosition(GetStdHandle(STD_OUTPUT_HANDLE), Coord);
  end;
end;

// Consumes Esc or Ctrl+C from any position in the input queue
function CheckAndConsumeCancel: boolean;
var
  Handle: THandle;
  Events: array of INPUT_RECORD = nil;
  NumEvents: DWORD = 0;
  NumRead: DWORD = 0;
  I, CancelIdx: integer;

// Returns True when event is Esc or Ctrl+C keydown
  function IsCancelEvent(const AR: INPUT_RECORD): boolean;
  begin
    Result := False;
    if AR.EventType <> KEY_EVENT then
      Exit;
    if not AR.Event.KeyEvent.bKeyDown then
      Exit;
    if AR.Event.KeyEvent.wVirtualKeyCode = VK_ESCAPE then
      Exit(True);
    if (AR.Event.KeyEvent.wVirtualKeyCode = VK_C) and ((AR.Event.KeyEvent.dwControlKeyState and
      (LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED)) <> 0) then
      Exit(True);
  end;

begin
  Result := False;
  Handle := GetStdHandle(STD_INPUT_HANDLE);
  if not GetNumberOfConsoleInputEvents(Handle, NumEvents) then
    Exit;
  if NumEvents = 0 then
    Exit;
  SetLength(Events, NumEvents);
  NumRead := 0;
  // Peek all pending events without consuming them
  if not PeekConsoleInput(Handle, Events[0], NumEvents, NumRead) then
    Exit;
  // Search for a cancel key anywhere in the queue
  CancelIdx := -1;
  for I := 0 to NumRead - 1 do
    if IsCancelEvent(Events[I]) then
    begin
      CancelIdx := I;
      Break;
    end;
  if CancelIdx < 0 then
    Exit;
  // Consume all events up to and including the cancel key
  ReadConsoleInput(Handle, Events[0], CancelIdx + 1, NumRead);
  Result := True;
end;

// Hides console cursor, used to suppress flicker during redraw
procedure HideConsoleCursor;
begin
  ConWriteUtf8(#27'[?25l');
end;

// Restores console cursor visibility, used after redraw
procedure ShowConsoleCursor;
begin
  ConWriteUtf8(#27'[?25h');
end;

function TCustomTermManager.ReadLine: string;
var
  Handle: THandle;
  Rec, NextRec: INPUT_RECORD;
  N: DWORD = 0;
  Line, PromptText: rawbytestring;
  CursorPos, HistIndex, PromptRow, PromptCol: integer;
  ScreenInfo: TConsoleScreenBufferInfo;
  C: widechar;
  Wide: unicodestring;
  LastRedrawRows: integer;
  HasMore, IsModifier, ShiftPressed, CtrlPressed, AltPressed: boolean;
  SelAnchor, SelStart, SelEnd: integer;
  HasSelection: boolean;
  MessageNavIndex: integer;
  DefaultAttr: word;

// Saves the cursor position where the current prompt begins
  procedure CapturePromptPosition;
  var
    Info: TConsoleScreenBufferInfo;
  begin
    FPendingScreenRow := -1;
    FPendingScreenCol := -1;

    Info := Default(TConsoleScreenBufferInfo);
    if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info) then
    begin
      FPendingScreenRow := Info.dwCursorPosition.Y;
      FPendingScreenCol := Info.dwCursorPosition.X;
    end;
  end;

  // Scrolls the console viewport without moving the input cursor
  procedure ScrollOutput(ADirection: integer);
  var
    Info: TConsoleScreenBufferInfo;
    Rect: SMALL_RECT;
    ViewHeight, MaxTop, NewTop: integer;
  begin
    Info := Default(TConsoleScreenBufferInfo);
    if not GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info) then
      Exit;

    Rect := Info.srWindow;
    ViewHeight := Rect.Bottom - Rect.Top + 1;
    if ViewHeight <= 0 then
      Exit;

    MaxTop := Info.dwSize.Y - ViewHeight;
    if MaxTop < 0 then
      MaxTop := 0;

    // Keep the input prompt inside the viewport
    NewTop := PromptRow + LastRedrawRows - ViewHeight - 1;
    if NewTop < 0 then
      NewTop := 0;
    if MaxTop > NewTop then
      MaxTop := NewTop;

    case ADirection of
      -2: NewTop := 0;
      2:
      begin
        // Place the current prompt near the middle of the viewport
        NewTop := Info.dwCursorPosition.Y - ViewHeight div 2;
      end;
      -3: NewTop := Rect.Top - 1;
      3: NewTop := Rect.Top + 1;
      -1: NewTop := Rect.Top - ViewHeight;
      1: NewTop := Rect.Top + ViewHeight;
      else
        Exit;
    end;

    if NewTop < 0 then
      NewTop := 0
    else if NewTop > MaxTop then
      NewTop := MaxTop;

    Rect.Top := NewTop;
    Rect.Bottom := NewTop + ViewHeight - 1;

    SetConsoleWindowInfo(GetStdHandle(STD_OUTPUT_HANDLE), True, Rect);
  end;

  // Moves the viewport to the previous or next user message
  procedure NavigateMessage(ADirection: integer);
  var
    Info: TConsoleScreenBufferInfo;
    Rect: SMALL_RECT;
    Mark: TTerminalOutputMark;
    ViewHeight, MaxTop, NewTop, MarksCount: integer;
    TargetIndex: integer;
  begin
    if not Assigned(FAgent) or not Assigned(FAgent.ActiveChat) then
      Exit;

    MarksCount := Length(FAgent.ActiveChat.OutputMarks);

    // The position after the last message represents the input prompt
    if ADirection < 0 then
    begin
      TargetIndex := MessageNavIndex;

      if TargetIndex > MarksCount then
        TargetIndex := MarksCount;

      Dec(TargetIndex);

      while TargetIndex >= 0 do
      begin
        Mark := FAgent.ActiveChat.OutputMarks[TargetIndex];
        if Mark.ScreenRow >= 0 then
          Break;
        Dec(TargetIndex);
      end;

      if TargetIndex < 0 then
        Exit;
    end
    else
    begin
      TargetIndex := MessageNavIndex + 1;

      while TargetIndex < MarksCount do
      begin
        Mark := FAgent.ActiveChat.OutputMarks[TargetIndex];
        if Mark.ScreenRow >= 0 then
          Break;
        Inc(TargetIndex);
      end;

      // Move to the input prompt after the last available message
      if TargetIndex >= MarksCount then
        TargetIndex := MarksCount;
    end;

    MessageNavIndex := TargetIndex;

    Info := Default(TConsoleScreenBufferInfo);
    if not GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info) then
      Exit;

    Rect := Info.srWindow;
    ViewHeight := Rect.Bottom - Rect.Top + 1;
    if ViewHeight <= 0 then
      Exit;

    MaxTop := Info.dwSize.Y - ViewHeight;
    if MaxTop < 0 then
      MaxTop := 0;

    // Keep the input prompt inside the viewport
    NewTop := PromptRow + LastRedrawRows - ViewHeight - 1;
    if NewTop < 0 then
      NewTop := 0;
    if MaxTop > NewTop then
      MaxTop := NewTop;

    if MessageNavIndex >= MarksCount then
      // Return to the input prompt after the last message
      NewTop := MaxTop
    else
    begin
      Mark := FAgent.ActiveChat.OutputMarks[MessageNavIndex];
      NewTop := Mark.ScreenRow - ViewHeight div 2;

      if NewTop < 0 then
        NewTop := 0
      else if NewTop > MaxTop then
        NewTop := MaxTop;
    end;

    Rect.Top := NewTop;
    Rect.Bottom := NewTop + ViewHeight - 1;
    SetConsoleWindowInfo(GetStdHandle(STD_OUTPUT_HANDLE), True, Rect);
  end;

  // Collects full UTF-8 sequence that conhost splits across key events
  procedure CollectBrokenUtf8(var AC: widechar);
  const
    WAIT_TIMEOUT_MS = 100;
    MAX_CONSUMED = 64;
  var
    Raw: rawbytestring;
    B, Nb, Attempts, TotalConsumed: integer;
    Skip: boolean;
  begin
    B := Ord(AC) and $FF;
    if not (B in [$C2..$F4]) then
      Exit;
    Raw := ansichar(B);
    if B >= $F0 then
      Nb := 3
    else if B >= $E0 then
      Nb := 2
    else
      Nb := 1;
    Skip := False;
    TotalConsumed := 0;
    while (Nb > 0) and not Skip do
    begin
      Attempts := 0;
      while (Attempts < WAIT_TIMEOUT_MS) and (TotalConsumed < MAX_CONSUMED) do
      begin
        if not PeekConsoleInput(Handle, NextRec, 1, N) then
        begin
          Skip := True;
          Break;
        end;
        if N = 0 then
        begin
          Sleep(1);
          Inc(Attempts);
          Continue;
        end;
        // Consume keyup and non-key events that sit between UTF-8 byte halves
        if (NextRec.EventType <> KEY_EVENT) or (not NextRec.Event.KeyEvent.bKeyDown) then
        begin
          ReadConsoleInput(Handle, NextRec, 1, N);
          Inc(TotalConsumed);
          Continue;
        end;
        B := Ord(NextRec.Event.KeyEvent.unicodechar) and $FF;
        if (B < $80) or (B > $BF) then
        begin
          Skip := True;
          Break;
        end;
        ReadConsoleInput(Handle, NextRec, 1, N);
        Raw := Raw + ansichar(B);
        Dec(Nb);
        Break;
      end;
      if Attempts >= WAIT_TIMEOUT_MS then
        Skip := True;
      if TotalConsumed >= MAX_CONSUMED then
        Skip := True;
    end;
    if Nb = 0 then
    begin
      Wide := UTF8Decode(Raw);
      if Length(Wide) > 0 then
        AC := Wide[1];
    end;
  end;

  // Splits text into lines, preserving trailing empty line after a line break
  function SplitLines(const S: rawbytestring): TStringList;
  var
    I, Start: integer;
  begin
    Result := TStringList.Create;
    Start := 1;
    I := 1;
    while I <= Length(S) do
    begin
      if S[I] = #13 then
      begin
        Result.Add(Copy(S, Start, I - Start));
        if (I < Length(S)) and (S[I + 1] = #10) then
          Inc(I, 2)
        else
          Inc(I);
        Start := I;
      end
      else if S[I] = #10 then
      begin
        Result.Add(Copy(S, Start, I - Start));
        Inc(I);
        Start := I;
      end
      else
        Inc(I);
    end;
    Result.Add(Copy(S, Start, MaxInt));
  end;

  // Recomputes normalized selection bounds from anchor and cursor position
  procedure UpdateSelection;
  begin
    HasSelection := (SelAnchor >= 0) and (SelAnchor <> CursorPos);
    if HasSelection then
    begin
      if SelAnchor < CursorPos then
      begin
        SelStart := SelAnchor;
        SelEnd := CursorPos;
      end
      else
      begin
        SelStart := CursorPos;
        SelEnd := SelAnchor;
      end;
    end
    else
    begin
      SelStart := 0;
      SelEnd := 0;
    end;
  end;

  // Resets the current text selection state
  procedure ClearSelection;
  begin
    SelAnchor := -1;
    HasSelection := False;
    SelStart := 0;
    SelEnd := 0;
  end;

  // Copies UTF-8 text to the Windows clipboard as CF_UNICODETEXT
  procedure CopyTextToClipboard(AText: rawbytestring);
  var
    SelWide: unicodestring;
    hData: THandle;
    P: Pointer;
    Size, SelLen: SizeInt;
  begin
    SetCodePage(AText, CP_UTF8, False);
    SelWide := UTF8Decode(AText);
    SelLen := Length(SelWide);
    if not OpenClipboard(0) then
      Exit;
    try
      EmptyClipboard;
      Size := (SelLen + 1) * SizeOf(widechar);
      hData := GlobalAlloc(GMEM_MOVEABLE or GMEM_ZEROINIT, Size);
      if hData = 0 then
        Exit;
      P := GlobalLock(hData);
      if P = nil then
      begin
        GlobalFree(hData);
        Exit;
      end;
      if SelLen > 0 then
        Move(SelWide[1], P^, SelLen * SizeOf(widechar));
      pwidechar(P)[SelLen] := #0;
      GlobalUnlock(hData);
      if SetClipboardData(CF_UNICODETEXT, hData) = 0 then
        GlobalFree(hData);
    finally
      CloseClipboard;
    end;
  end;

  // Copies the selected input range to the clipboard
  procedure CopySelectionToClipboard;
  var
    SelText: rawbytestring;
  begin
    if not HasSelection then
      Exit;
    SelText := Copy(Line, SelStart + 1, SelEnd - SelStart);
    CopyTextToClipboard(SelText);
  end;

  // Copies the active chat output without internal color markers
  procedure CopyChatToClipboard;
  var
    ChatText: rawbytestring;
    I: integer;
  begin
    if not Assigned(FAgent) or not Assigned(FAgent.ActiveChat) then
      Exit;

    ChatText := FAgent.ActiveChat.TerminalOutput;
    I := 1;
    while I <= Length(ChatText) do
    begin
      if ChatText[I] = #2 then
        Delete(ChatText, I, 2)
      else
        Inc(I);
    end;

    CopyTextToClipboard(ChatText);
  end;

  // Reads clipboard text as a Unicode string, returns empty when clipboard has no text
  function ReadClipboardText: unicodestring;
  var
    hData: THandle;
    P: Pointer;
  begin
    Result := '';
    if not IsClipboardFormatAvailable(CF_UNICODETEXT) then
      Exit;
    if not OpenClipboard(0) then
      Exit;
    try
      hData := GetClipboardData(CF_UNICODETEXT);
      if hData = 0 then
        Exit;
      P := GlobalLock(hData);
      if P = nil then
        Exit;
      try
        Result := pwidechar(P);
      finally
        GlobalUnlock(hData);
      end;
    finally
      CloseClipboard;
    end;
  end;

  // Normalizes line endings to CRLF and inserts clipboard text at cursor
  procedure PasteText(const AText: unicodestring);
  var
    Utf8: rawbytestring;
  begin
    if Length(AText) = 0 then
      Exit;
    Utf8 := UTF8Encode(AText);
    SetCodePage(Utf8, CP_UTF8, False);
    // Normalize all line ending variants to Windows CRLF
    Utf8 := StringReplace(Utf8, #13#10, #10, [rfReplaceAll]);
    Utf8 := StringReplace(Utf8, #13, #10, [rfReplaceAll]);
    Utf8 := StringReplace(Utf8, #10, #13#10, [rfReplaceAll]);
    if HasSelection then
    begin
      Delete(Line, SelStart + 1, SelEnd - SelStart);
      CursorPos := SelStart;
      ClearSelection;
    end;
    Insert(Utf8, Line, CursorPos + 1);
    SetCodePage(Line, CP_UTF8, False);
    Inc(CursorPos, Length(Utf8));
  end;

  // Moves cursor vertically within logical lines, returns False at edges
  function MoveCursorVertical(ADelta: integer): boolean;
  var
    I, Idx, LineStart, TargetStart, TargetLen, Col: integer;
    TargetPos, TargetBytePos: integer;
    Lines: TStringList;
  begin
    Result := False;
    if Pos(LineEnding, Line) = 0 then
      Exit;
    Lines := SplitLines(Line);
    try
      if Lines.Count < 2 then
        Exit;
      Idx := -1;
      LineStart := 0;
      for I := 0 to Lines.Count - 1 do
      begin
        if (CursorPos >= LineStart) and (CursorPos <= LineStart + Length(Lines[I])) then
        begin
          Idx := I;
          Break;
        end;
        LineStart := LineStart + Length(Lines[I]) + 2;
      end;
      if Idx < 0 then
        Exit;
      if (Idx + ADelta < 0) or (Idx + ADelta >= Lines.Count) then
        Exit;
      TargetStart := 0;
      for I := 0 to Idx + ADelta - 1 do
        Inc(TargetStart, Length(Lines[I]) + 2);
      Col := Utf8CharCount(Copy(Lines[Idx], 1, CursorPos - LineStart));
      TargetLen := Utf8CharCount(Lines[Idx + ADelta]);
      if Col > TargetLen then
        Col := TargetLen;
      TargetPos := 1;
      TargetBytePos := 0;
      for I := 1 to Col do
      begin
        TargetBytePos := Utf8NextPos(Lines[Idx + ADelta], TargetPos) - 1;
        TargetPos := TargetBytePos + 1;
      end;
      CursorPos := TargetStart + TargetBytePos;
      Result := True;
    finally
      Lines.Free;
    end;
  end;

  // Moves cursor vertically within a visually wrapped line
  function MoveCursorWrapped(ADelta: integer): boolean;
  var
    Info: TConsoleScreenBufferInfo;
    Width, CharCol, TotalChars, CurrentRow, CurrentCol: integer;
    TargetRow, TargetCharCol, TargetBytePos, I: integer;
  begin
    Result := False;
    if (Length(Line) = 0) or (Pos(LineEnding, Line) > 0) then
      Exit;
    Info := Default(TConsoleScreenBufferInfo);
    if not GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info) then
      Exit;
    Width := Info.dwSize.X;
    if Width <= 0 then
      Exit;
    CharCol := Utf8CharCount(Copy(Line, 1, CursorPos));
    TotalChars := Utf8CharCount(Line);
    CurrentRow := (PromptCol + CharCol) div Width;
    CurrentCol := (PromptCol + CharCol) mod Width;
    TargetRow := CurrentRow + ADelta;
    if TargetRow < 0 then
      Exit;
    // Do not move beyond the last visual row
    if TargetRow > (PromptCol + TotalChars - 1) div Width then
      Exit;
    TargetCharCol := TargetRow * Width + CurrentCol - PromptCol;
    if TargetCharCol < 0 then
      TargetCharCol := 0;
    if TargetCharCol > TotalChars then
      TargetCharCol := TotalChars;
    TargetBytePos := 0;
    I := 0;
    while (I < TargetCharCol) and (TargetBytePos < Length(Line)) do
    begin
      TargetBytePos := Utf8NextPos(Line, TargetBytePos + 1) - 1;
      Inc(I);
    end;
    CursorPos := TargetBytePos;
    Result := True;
  end;

  // Inserts a UTF-8 char at the cursor, replacing the selection when active
  procedure InsertTypedChar(const AUtf8: rawbytestring);
  var
    OldLen: integer;
  begin
    if HasSelection then
    begin
      Delete(Line, SelStart + 1, SelEnd - SelStart);
      CursorPos := SelStart;
      ClearSelection;
    end;
    OldLen := Length(Line);
    Insert(AUtf8, Line, CursorPos + 1);
    SetCodePage(Line, CP_UTF8, False);
    Inc(CursorPos, Length(Line) - OldLen);
  end;

  // Redraws prompt and content, tracks visual wrapping and selection highlight
  procedure Redraw;
  var
    I, J, J2, LenS, GlobalPos, LineStart: integer;
    S: rawbytestring;
    Lines: TStringList;
    Info: CONSOLE_SCREEN_BUFFER_INFO;
    NormalAttr, InvAttr: word;
    IsSel, PrevIsSel: boolean;
    CurRow, CurCol, NewRows: integer;
    CursorSaved: boolean;
  begin
    HideConsoleCursor;
    Info := Default(CONSOLE_SCREEN_BUFFER_INFO);
    GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info);
    NormalAttr := Info.wAttributes;
    // Swap foreground and background to build the selection highlight
    InvAttr := ((NormalAttr and $0F) shl 4) or ((NormalAttr and $F0) shr 4);

    Lines := SplitLines(Line);
    try
      ConGotoXY(1, PromptRow);
      CapturePromptPosition;
      CursorSaved := False;
      CurRow := PromptRow;
      CurCol := 1;
      LineStart := 1;

      for I := 0 to Lines.Count - 1 do
      begin
        if I = 0 then
          ConWriteUtf8(PromptText);
        S := Lines[I];
        LenS := Length(S);

        if HasSelection then
        begin
          // Slow path: char by char so attribute can change at boundaries
          PrevIsSel := False;
          J := 1;
          while J <= LenS do
          begin
            GlobalPos := LineStart - 1 + (J - 1);
            IsSel := (GlobalPos >= SelStart) and (GlobalPos < SelEnd);
            if IsSel <> PrevIsSel then
            begin
              if IsSel then
                SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), InvAttr)
              else
                SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), NormalAttr);
              PrevIsSel := IsSel;
            end;
            if (not CursorSaved) and (CursorPos = GlobalPos) then
            begin
              GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info);
              CurRow := Info.dwCursorPosition.Y + 1;
              CurCol := Info.dwCursorPosition.X + 1;
              CursorSaved := True;
            end;
            J2 := Utf8NextPos(S, J);
            ConWriteUtf8(Copy(S, J, J2 - J));
            J := J2;
          end;
          if PrevIsSel then
            SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), NormalAttr);
        end
        else
        begin
          // Fast path: split around cursor byte offset and capture between
          J := CursorPos - (LineStart - 1);
          if (not CursorSaved) and (J >= 0) and (J <= LenS) then
          begin
            if J > 0 then
              ConWriteUtf8(Copy(S, 1, J));
            GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info);
            CurRow := Info.dwCursorPosition.Y + 1;
            CurCol := Info.dwCursorPosition.X + 1;
            CursorSaved := True;
            if J < LenS then
              ConWriteUtf8(Copy(S, J + 1, MaxInt));
          end
          else
            ConWriteUtf8(S);
        end;

        // Capture cursor at end of logical line content for the slow path
        if (not CursorSaved) and (CursorPos = LineStart - 1 + LenS) then
        begin
          GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info);
          CurRow := Info.dwCursorPosition.Y + 1;
          CurCol := Info.dwCursorPosition.X + 1;
          CursorSaved := True;
        end;

        if I < Lines.Count - 1 then
        begin
          // Clear unused space with the default console attributes
          SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), DefaultAttr);
          ConClearLineFromCursor;
          SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), NormalAttr);
          GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info);
          if Info.dwCursorPosition.X > 0 then
            ConGotoXY(1, Info.dwCursorPosition.Y + 2)
          else
            ConGotoXY(1, Info.dwCursorPosition.Y + 1);
          LineStart := LineStart + LenS + 2;
        end;
      end;

      if not CursorSaved then
      begin
        GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info);
        CurRow := Info.dwCursorPosition.Y + 1;
        CurCol := Info.dwCursorPosition.X + 1;
      end;

      GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info);

      // Clear unused space with the default console attributes
      SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), DefaultAttr);
      ConClearLineFromCursor;

      GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info);
      if Info.dwCursorPosition.X = 0 then
        NewRows := Info.dwCursorPosition.Y + 1 - PromptRow
      else
        NewRows := Info.dwCursorPosition.Y + 2 - PromptRow;
      if NewRows < 1 then
        NewRows := 1;
      // Clear trailing rows that were used before but are now empty
      if NewRows < LastRedrawRows then
        for I := NewRows to LastRedrawRows - 1 do
        begin
          ConGotoXY(1, PromptRow + I);
          ConClearLineFromCursor;
        end;

      // Restore prompt attributes for subsequent input editing
      SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), NormalAttr);
      LastRedrawRows := NewRows;
    finally
      Lines.Free;
    end;

    ConGotoXY(CurCol, CurRow);
    ShowConsoleCursor;
  end;

  // Returns byte offset of the start of the logical line containing APos
  function FindLineStart(APos: integer): integer;
  var
    I: integer;
  begin
    I := APos;
    while I > 0 do
    begin
      if (Line[I] = #10) or (Line[I] = #13) then
        Exit(I);
      Dec(I);
    end;
    Result := 0;
  end;

  // Moves the cursor to the beginning or end of the input text
  procedure PositionInputCursor(AToEnd: boolean);
  begin
    if AToEnd then
      CursorPos := Length(Line)
    else
      CursorPos := 0;

    ClearSelection;
  end;

  // Returns byte offset of the end of the logical line containing APos
  function FindLineEnd(APos: integer): integer;
  var
    I: integer;
  begin
    I := APos + 1;
    while I <= Length(Line) do
    begin
      if (Line[I] = #10) or (Line[I] = #13) then
        Exit(I - 1);
      Inc(I);
    end;
    Result := Length(Line);
  end;

  // Reset the input buffer and redraw the prompt
  procedure ResetInput;
  begin
    Line := string.Empty;
    CursorPos := 0;
    HistIndex := FHistory.Count;
    ClearSelection;

    PromptText := GetPromptText;
    CapturePromptPosition;
    SetColor(tcPromptInput);
    ConWriteUtf8(PromptText);
    FLastCharWasNewLine := False;
    PromptRow := ConWhereY;
    ScreenInfo := Default(TConsoleScreenBufferInfo);
    PromptCol := 0;
    if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), ScreenInfo) then
      PromptCol := ScreenInfo.dwCursorPosition.X;
    LastRedrawRows := 1;
  end;

  {$IFDEF WINDOWS}
  procedure ForceConsoleRedraw;
  var
    ConsoleWindow: HWND;
  begin
    ConsoleWindow := GetConsoleWindow;
    if ConsoleWindow <> 0 then
      RedrawWindow(ConsoleWindow, nil, 0,
        RDW_INVALIDATE or RDW_ERASE or RDW_UPDATENOW);
  end;
  {$ENDIF}
begin
  Result := '';
  Rec := Default(INPUT_RECORD);
  Line := '';
  SetCodePage(Line, CP_UTF8, False);
  CursorPos := 0;
  HistIndex := FHistory.Count;
  SelAnchor := -1;
  HasSelection := False;
  SelStart := 0;
  SelEnd := 0;

  PromptText := GetPromptText;
  // Ensure prompt starts on a fresh line after streaming output
  if not FLastCharWasNewLine then
    ConWriteUtf8(LineEnding);

  CapturePromptPosition;

  MessageNavIndex := 0;
  if Assigned(FAgent) and Assigned(FAgent.ActiveChat) then
    MessageNavIndex := Length(FAgent.ActiveChat.OutputMarks);

  Handle := GetStdHandle(STD_INPUT_HANDLE);
  // Drop input events accumulated while the agent was streaming, a paste
  // sent to a busy console would otherwise flood Line on the next read
  if (Handle <> 0) and (Handle <> INVALID_HANDLE_VALUE) then
  try
    FlushConsoleInputBuffer(Handle);
  except
    ; // Console may be detached
  end;

  // Preserve the default console attributes for clearing unused line space
  ScreenInfo := Default(TConsoleScreenBufferInfo);
  DefaultAttr := 0;
  if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), ScreenInfo) then
    DefaultAttr := ScreenInfo.wAttributes;

  SetColor(tcPromptInput);
  ConWriteUtf8(PromptText);
  FLastCharWasNewLine := False;
  PromptRow := ConWhereY;
  ScreenInfo := Default(TConsoleScreenBufferInfo);
  PromptCol := 0;
  if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), ScreenInfo) then
    PromptCol := ScreenInfo.dwCursorPosition.X;
  LastRedrawRows := 1;

  while FRunning do
  begin
    if not ReadConsoleInput(Handle, Rec, 1, N) then
      Break;
    if Rec.EventType <> KEY_EVENT then
      Continue;
    if not Rec.Event.KeyEvent.bKeyDown then
      Continue;

    C := Rec.Event.KeyEvent.unicodechar;
    // Two conhost variants observed in the wild for UTF-8 input:
    //   high-byte wrapper ($FFxx) - raw byte sits in the low 8 bits
    //   plain byte       ($00xx) - UTF-8 lead byte sits in the low 8 bits
    // Both need CollectBrokenUtf8 to assemble the full sequence
    if (Ord(C) >= $FF00) or ((Ord(C) >= $C2) and (Ord(C) <= $F4)) then
      CollectBrokenUtf8(C);

    ShiftPressed := (Rec.Event.KeyEvent.dwControlKeyState and SHIFT_PRESSED) <> 0;
    CtrlPressed := (Rec.Event.KeyEvent.dwControlKeyState and (LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED)) <> 0;
    AltPressed := (Rec.Event.KeyEvent.dwControlKeyState and (LEFT_ALT_PRESSED or RIGHT_ALT_PRESSED)) <> 0;

    // Ignore standalone modifier keys to preserve the current viewport
    if Rec.Event.KeyEvent.wVirtualKeyCode in [VK_SHIFT, VK_CONTROL, VK_MENU] then
      Continue;

    // Delete the active chat with Ctrl+Shift+Delete
    if CtrlPressed and ShiftPressed and (Rec.Event.KeyEvent.wVirtualKeyCode = VK_DELETE) then
    begin
      if Assigned(FAgent) and Assigned(FAgent.ActiveChat) then
      begin
        if ConfirmDeleteChat(FAgent.ActiveChat.Name) then
        begin
          if FAgent.DeleteActiveChat then
          begin
            RestoreActiveChat;
            UpdateConsoleTitle;
          end;
        end;

        ResetInput;
        Continue;
      end;
    end;

    // Move the active chat with Ctrl+Shift+Left and Ctrl+Shift+Right
    if CtrlPressed and ShiftPressed and (Rec.Event.KeyEvent.wVirtualKeyCode in [VK_LEFT, VK_RIGHT]) then
    begin
      // Preserve the current input in the active chat before switching
      if Line <> string.Empty then
        AddToHistory(Line);

      if Rec.Event.KeyEvent.wVirtualKeyCode = VK_LEFT then
        HasMore := MoveActiveChat(-1)
      else
        HasMore := MoveActiveChat(1);

      if HasMore then
      begin
        Line := string.Empty;
        CursorPos := 0;
        HistIndex := FHistory.Count;
        ClearSelection;

        PromptText := GetPromptText;
        SetColor(tcPromptInput);
        Redraw;
        FLastCharWasNewLine := False;

        ScreenInfo := Default(TConsoleScreenBufferInfo);
        if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), ScreenInfo) then
          PromptCol := ScreenInfo.dwCursorPosition.X;

        LastRedrawRows := 1;
      end;
      Continue;
    end;

    // Switch chats with Ctrl+Left and Ctrl+Right
    if CtrlPressed and not ShiftPressed and (Rec.Event.KeyEvent.wVirtualKeyCode in [VK_LEFT, VK_RIGHT]) then
    begin
      // Save the current input before changing the active chat
      if Line <> string.Empty then
        AddToHistory(Line);

      if Rec.Event.KeyEvent.wVirtualKeyCode = VK_LEFT then
        HasMore := SwitchActiveChat(-1)
      else
        HasMore := SwitchActiveChat(1);

      if HasMore then
      begin
        Line := string.Empty;
        CursorPos := 0;
        HistIndex := FHistory.Count;
        ClearSelection;

        PromptText := GetPromptText;
        SetColor(tcPromptInput);
        ConWriteUtf8(PromptText);
        FLastCharWasNewLine := False;
        PromptRow := ConWhereY;
        ScreenInfo := Default(TConsoleScreenBufferInfo);
        PromptCol := 0;
        if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), ScreenInfo) then
          PromptCol := ScreenInfo.dwCursorPosition.X;
        LastRedrawRows := 1;
        Continue;
      end;
    end;

    case Rec.Event.KeyEvent.wVirtualKeyCode of
      VK_RETURN:
      begin
        IsModifier := ShiftPressed or CtrlPressed;
        HasMore := False;
        if not IsModifier then
        begin
          while PeekConsoleInput(Handle, NextRec, 1, N) and (N > 0) do
          begin
            if (NextRec.EventType = KEY_EVENT) and NextRec.Event.KeyEvent.bKeyDown then
            begin
              HasMore := True;
              Break;
            end;
            if not ReadConsoleInput(Handle, NextRec, 1, N) then
              Break;
          end;
        end
        else
        begin
          if PeekConsoleInput(Handle, NextRec, 1, N) and (N > 0) then
            if (NextRec.EventType = KEY_EVENT) and (NextRec.Event.KeyEvent.wVirtualKeyCode = VK_RETURN) and
              (not NextRec.Event.KeyEvent.bKeyDown) then
              ReadConsoleInput(Handle, NextRec, 1, N);
        end;
        if IsModifier or HasMore then
        begin
          // Replace selection and insert the line ending at the cursor
          if HasSelection then
          begin
            Delete(Line, SelStart + 1, SelEnd - SelStart);
            CursorPos := SelStart;
            ClearSelection;
          end;

          Insert(LineEnding, Line, CursorPos + 1);
          Inc(CursorPos, Length(LineEnding));
        end
        else
        begin
          // Move below all visual rows occupied by the input
          ConGotoXY(1, PromptRow + LastRedrawRows);
          ForceConsoleRedraw;
          FLastCharWasNewLine := True;
          Break;
        end;
      end;
      VK_BACK:
      begin
        // Remove the previous input and its result with Ctrl+Backspace
        if CtrlPressed and RemoveLastInput then
        begin
          if not FLastInputScreenCleared then
            RestoreActiveChat
          else
            ScrollOutput(2);

          ResetInput;
          Continue;
        end;

        if HasSelection then
        begin
          Delete(Line, SelStart + 1, SelEnd - SelStart);
          CursorPos := SelStart;
          ClearSelection;
        end
        else if CursorPos > 0 then
        begin
          if (CursorPos >= 2) and (Line[CursorPos] = #10) and (Line[CursorPos - 1] = #13) then
          begin
            Dec(CursorPos, 2);
            Delete(Line, CursorPos + 1, 2);
          end
          else
          begin
            CursorPos := Utf8PrevPos(Line, CursorPos);
            Delete(Line, CursorPos + 1, Utf8NextPos(Line, CursorPos + 1) - CursorPos - 1);
          end;
        end;
      end;
      VK_DELETE:
      begin
        if HasSelection then
        begin
          Delete(Line, SelStart + 1, SelEnd - SelStart);
          CursorPos := SelStart;
          ClearSelection;
        end
        else if CtrlPressed and (HistIndex >= 0) and (HistIndex < FHistory.Count) and (Line = FHistory[HistIndex]) then
        begin
          FHistory.Delete(HistIndex);

          // Synchronize the active chat terminal history
          if Assigned(FAgent) and Assigned(FAgent.ActiveChat) then
          begin
            FAgent.ActiveChat.TerminalHistory.Assign(FHistory);
            FAgent.ActiveChat.MarkSessionActive;
          end;

          if HistIndex > 0 then
            Dec(HistIndex);
          if FHistory.Count = 0 then
          begin
            Line := '';
            CursorPos := 0;
            HistIndex := 0;
          end
          else
          begin
            if HistIndex >= FHistory.Count then
              HistIndex := FHistory.Count - 1;
            Line := FHistory[HistIndex];
            SetCodePage(Line, CP_UTF8, False);
            CursorPos := Length(Line);
          end;
        end
        else if CursorPos < Length(Line) then
        begin
          if (Line[CursorPos + 1] = #13) and (CursorPos + 1 < Length(Line)) and (Line[CursorPos + 2] = #10) then
            Delete(Line, CursorPos + 1, 2)
          else
            Delete(Line, CursorPos + 1, Utf8NextPos(Line, CursorPos + 1) - CursorPos - 1);
        end;
      end;
      VK_LEFT:
      begin
        if ShiftPressed and not HasSelection then
          SelAnchor := CursorPos
        else if not ShiftPressed then
          ClearSelection;
        if CursorPos > 0 then
        begin
          if (CursorPos >= 2) and (Line[CursorPos] = #10) and (Line[CursorPos - 1] = #13) then
            Dec(CursorPos, 2)
          else
            CursorPos := Utf8PrevPos(Line, CursorPos);
        end;
        if ShiftPressed then
          UpdateSelection;
      end;
      VK_RIGHT:
      begin
        if ShiftPressed and not HasSelection then
          SelAnchor := CursorPos
        else if not ShiftPressed then
          ClearSelection;
        // Utf8NextPos returns 1-based next char start, subtract 1 for byte count
        if CursorPos < Length(Line) then
        begin
          if (CursorPos + 2 <= Length(Line)) and (Line[CursorPos + 1] = #13) and (Line[CursorPos + 2] = #10) then
            Inc(CursorPos, 2)
          else
            CursorPos := Utf8NextPos(Line, CursorPos + 1) - 1;
        end;
        if ShiftPressed then
          UpdateSelection;
      end;
      VK_PRIOR:
      begin
        if AltPressed and not CtrlPressed then
          NavigateMessage(-1)
        else if ShiftPressed and not CtrlPressed then
          ScrollOutput(-3)
        else
          ScrollOutput(-1);
        Continue;
      end;
      VK_NEXT:
      begin
        if AltPressed and not CtrlPressed then
          NavigateMessage(1)
        else if ShiftPressed and not CtrlPressed then
          ScrollOutput(3)
        else
          ScrollOutput(1);
        Continue;
      end;
      VK_HOME:
      begin
        if CtrlPressed then
          PositionInputCursor(False)
        else if Line = string.Empty then
        begin
          ScrollOutput(-2);
          Continue;
        end
        else
        begin
          if ShiftPressed and not HasSelection then
            SelAnchor := CursorPos
          else if not ShiftPressed then
            ClearSelection;
          // Jump to start of the current logical line, not the buffer
          CursorPos := FindLineStart(CursorPos);
          if ShiftPressed then
            UpdateSelection;
        end;
      end;
      VK_END:
      begin
        if CtrlPressed then
          PositionInputCursor(True)
        else if Line = string.Empty then
        begin
          ScrollOutput(2);
          Continue;
        end
        else
        begin
          if ShiftPressed and not HasSelection then
            SelAnchor := CursorPos
          else if not ShiftPressed then
            ClearSelection;
          // Jump to end of the current logical line, not the buffer
          CursorPos := FindLineEnd(CursorPos);
          if ShiftPressed then
            UpdateSelection;
        end;
      end;
      VK_UP:
        if CtrlPressed and ShiftPressed then
        begin
          if FHistory.Count > 0 then
          begin
            HistIndex := 0;
            Line := FHistory[HistIndex];
            SetCodePage(Line, CP_UTF8, False);
            PositionInputCursor(False);
          end;
        end
        else if CtrlPressed then
        begin
          if HistIndex = FHistory.Count then
          begin
            if Line <> '' then
              AddToHistory(Line);
            HistIndex := FHistory.Count - 1;
          end
          else if HistIndex > 0 then
            Dec(HistIndex);

          if (HistIndex >= 0) and (HistIndex < FHistory.Count) then
          begin
            Line := FHistory[HistIndex];
            SetCodePage(Line, CP_UTF8, False);
            PositionInputCursor(False);
          end;
        end
        else
        begin
          ClearSelection;
          // Move within visual or logical lines first, fall back to history at top
          if Pos(LineEnding, Line) = 0 then
            HasMore := MoveCursorWrapped(-1)
          else
            HasMore := MoveCursorVertical(-1);
          if not HasMore then
          begin
            if HistIndex = FHistory.Count then
            begin
              // Save current live input so it can be recovered via VK_DOWN
              if Line <> '' then
              begin
                AddToHistory(Line);
                HistIndex := FHistory.Count - 2;
              end
              else
                HistIndex := FHistory.Count - 1;
              if HistIndex < 0 then
                HistIndex := 0;
            end
            else if HistIndex > 0 then
              Dec(HistIndex);
            if (HistIndex >= 0) and (HistIndex < FHistory.Count) then
            begin
              Line := FHistory[HistIndex];
              SetCodePage(Line, CP_UTF8, False);
              PositionInputCursor(False);
            end;
          end;
        end;
      VK_DOWN:
        if CtrlPressed and ShiftPressed then
        begin
          if FHistory.Count > 0 then
          begin
            HistIndex := FHistory.Count - 1;
            Line := FHistory[HistIndex];
            SetCodePage(Line, CP_UTF8, False);
            PositionInputCursor(True);
          end;
        end
        else if CtrlPressed then
        begin
          if HistIndex < FHistory.Count - 1 then
          begin
            Inc(HistIndex);
            Line := FHistory[HistIndex];
            SetCodePage(Line, CP_UTF8, False);
            CursorPos := Length(Line);
          end
          else if HistIndex = FHistory.Count - 1 then
          begin
            HistIndex := FHistory.Count;
            Line := '';
            CursorPos := 0;
          end;
        end
        else
        begin
          ClearSelection;
          // Move within visual or logical lines first, fall back to history at bottom
          if Pos(LineEnding, Line) = 0 then
            HasMore := MoveCursorWrapped(1)
          else
            HasMore := MoveCursorVertical(1);
          if not HasMore then
          begin
            if HistIndex < FHistory.Count - 1 then
            begin
              Inc(HistIndex);
              Line := FHistory[HistIndex];
              SetCodePage(Line, CP_UTF8, False);
              PositionInputCursor(True);
            end
            else if HistIndex = FHistory.Count - 1 then
            begin
              HistIndex := FHistory.Count;
              Line := '';
              CursorPos := 0;
            end;
          end;
        end;
      VK_ESCAPE:
      begin
        Line := '';
        CursorPos := 0;
        ClearSelection;
      end;
      VK_N:
        if CtrlPressed then
        begin
          // Preserve the current input before creating a new chat
          if Line <> string.Empty then
            AddToHistory(Line);

          HandleBuiltin('new');
          ResetInput;
          Continue;
        end
        else if Ord(C) >= 32 then
          InsertTypedChar(WideCharToUtf8(C));
      VK_V:
        if CtrlPressed then
          PasteText(ReadClipboardText)
        else if Ord(C) >= 32 then
          InsertTypedChar(WideCharToUtf8(C));
      VK_A:
        if CtrlPressed then
        begin
          if Line = string.Empty then
            CopyChatToClipboard
          else
          begin
            SelAnchor := 0;
            CursorPos := Length(Line);
            UpdateSelection;
          end;
        end
        else if Ord(C) >= 32 then
          InsertTypedChar(WideCharToUtf8(C));
      VK_C:
        if CtrlPressed then
        begin
          if HasSelection then
          begin
            CopySelectionToClipboard;
            ClearSelection;
          end
          else
          begin
            ConGotoXY(1, PromptRow);
            ConClearLineFromCursor;
            ConWriteUtf8(PromptText);
            ConWriteUtf8(Line);
            ConWriteUtf8('^C');
            ConWriteUtf8(LineEnding);
            Line := '';
            CursorPos := 0;
            HistIndex := FHistory.Count;
            SetColor(tcPromptInput);
            ConWriteUtf8(PromptText);
            FLastCharWasNewLine := False;
            PromptRow := ConWhereY;
            LastRedrawRows := 1;
            Continue;
          end;
        end
        else if Ord(C) >= 32 then
          InsertTypedChar(WideCharToUtf8(C));
      else
        if Ord(C) >= 32 then
          InsertTypedChar(WideCharToUtf8(C));
    end;

    try
      Redraw;
    except
      ; // Console may be detached mid-redraw, keep the input loop alive
    end;
  end;

  Result := Line;
  AddToHistory(Result);
  FPendingOutputStart := -1;

  if not IsChatControlCommand(Result) then
  begin
    if Assigned(FAgent) and Assigned(FAgent.ActiveChat) then
      FPendingOutputStart := Length(FAgent.ActiveChat.TerminalOutput);

    AppendChatOutput(string(PromptText) + string(Line) + LineEnding);
  end;

  SetColor(tcDefault);
end;

{$ELSE}

procedure TCustomTermManager.SetColor(AColor: TTermColor);
begin
  // Store color changes for chat history replay
  AppendChatOutput(#2 + Chr(Ord(AColor)));
end;

procedure ConGotoXY(X, Y: integer);
begin
  Write(Format(#27'[%d;%dH', [Y, X]));
end;

function ConWhereY: integer;
begin
  Result := 1;
end;

procedure ConClearLineFromCursor;
begin
  Write(#27'[K');
end;

procedure ClearScreen;
begin
  Write(#27'[2J'#27'[H');
end;

function CheckAndConsumeCancel: boolean;
begin
  Result := False;
end;

function TCustomTermManager.ReadLine: string;
var
  S, PromptText: string;
begin
  Result := string.Empty;
  PromptText := GetPromptText;
  Write(PromptText);
  if not FRunning then
    Exit;
  ReadLn(S);
  Result := S;
  AddToHistory(S);
  FPendingOutputStart := -1;

  if not IsChatControlCommand(Result) then
  begin
    if Assigned(FAgent) and Assigned(FAgent.ActiveChat) then
      FPendingOutputStart := Length(FAgent.ActiveChat.TerminalOutput);

    AppendChatOutput(PromptText + S + LineEnding);
  end;
end;

{$ENDIF}

end.
