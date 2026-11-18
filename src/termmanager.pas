//-----------------------------------------------------------------------------------
//  OllamaKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit TermManager;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, DateUtils, Process, fpjson, jsonparser, TypInfo,
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
  TTermColor = (tcDefault, tcDim, tcWelcome, tcThinkingBadge, tcToolBadge, tcErrorBadge, tcWarnBadge);

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
    procedure SetWelcomeBadge(const AValue: TConsoleColorPair);
    procedure SetThinkingBadge(const AValue: TConsoleColorPair);
    procedure SetToolBadge(const AValue: TConsoleColorPair);
    procedure SetErrorBadge(const AValue: TConsoleColorPair);
    procedure SetWarnBadge(const AValue: TConsoleColorPair);
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
    // Previous agent handlers, restored when agent is detached
    FPrevAgentOnChunk: TAgentChunkEvent;
    FPrevAgentOnLog: TAgentLogEvent;
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
    procedure SetPath(const AValue: string);
    procedure SetAgent(const AValue: TCustomOllamaAgent);
    procedure SetHistory(const AValue: TStringList);
    procedure SetColors(const AValue: TTermColorScheme);
    procedure SetShellHistory(const AValue: TAgentShellHistory);
    // Handles help, help agent, and ? alias
    procedure HandleHelpCommand(const AArg: string);
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
    // Handlers for the various ollama subcommands
    procedure HandleOllamaList;
    procedure HandleOllamaPs;
    procedure HandleOllamaShow(const AModel: string);
    procedure HandleOllamaPull(const AModel: string);
    procedure HandleOllamaRm(const AModel: string);
    procedure HandleOllamaStop(const AModel: string);
    procedure HandleOllamaLoad(const AModel: string);
    procedure HandleOllamaUnload(const AModel: string);
    procedure HandleOllamaCopy(const ASource, ADest: string);
    procedure HandleOllamaCreate(const AName, AFile: string);
    procedure HandleOllamaVersion;
    procedure HandleOllamaHelp;
    // Temporary event handlers used while a command is in flight
    procedure HandleOllamaModelsRefreshed(Sender: TObject; const Models: TStringList);
    procedure HandleOllamaError(Sender: TObject; Kind: TOllamaErrorKind; const ModelName, Msg: string);
    procedure HandleOllamaPullProgress(Sender: TObject; const ModelName: string; Percent: integer);
    // Pumps sync events until the pending ollama operation finishes or times out
    function WaitOllamaOp(ATimeoutMs: integer): boolean;
    // Reads a small text file as string, returns empty when read fails
    function ReadSmallTextFile(const APath: string): string;
    // Formats a byte count as human-readable string like "23.4 GB"
    function BytesToHumanText(const ABytes: int64): string;
  protected
    // Clears agent reference when it is removed at runtime
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    // Applies a semantic color to subsequent output, no-op on non-Windows
    procedure SetColor(AColor: TTermColor); virtual;
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
    // Executes agent shell command through configured shell and returns output
    procedure HandleAgentExecCommand(Sender: TObject; const ACommand: string; var AResult: string; var AAllow: boolean);
    // Prompts the user with a question and returns the typed answer
    procedure HandleAgentAskUser(Sender: TObject; const AQuestion: string; var AAnswer: string; var AAllow: boolean);
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
    // Returns multi-line help for term.* properties
    function FormatTermHelp: string; virtual;
    // Returns multi-line current values of term.* properties
    function FormatTermConfig: string; virtual;

    property Path: string read FPath write SetPath;
    property Prompt: string read FPrompt write FPrompt;
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
    // Prompt template, supports {path}, {model}, {context}, {context_kb}, {context_percent} and other usage placeholders
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
    '|ssh|ssh.exe|ssh-keygen|ssh-keygen.exe|scp|scp.exe|sftp|sftp.exe|' +
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
end;

destructor TTermColorScheme.Destroy;
begin
  FWelcomeBadge.Free;
  FThinkingBadge.Free;
  FToolBadge.Free;
  FErrorBadge.Free;
  FWarnBadge.Free;
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
  FPrevAgentOnChunk := nil;
  FPrevAgentOnThinking := nil;
  FPrevAgentOnToolCall := nil;
  FPrevAgentOnToolResult := nil;
  FPrevAgentOnFinish := nil;
  FPrevAgentOnExecCommand := nil;
  FPrevAgentOnAskUser := nil;
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

procedure TCustomTermManager.SetPath(const AValue: string);
var
  NewPath: string;
begin
  if AValue = '' then
  begin
    FPath := '';
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
  end;
end;

procedure TCustomTermManager.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FAgent) then
    SetAgent(nil);
end;

procedure TCustomTermManager.SetAgent(const AValue: TCustomOllamaAgent);
begin
  if FAgent = AValue then
    Exit;
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
    // Share shell name with the agent at runtime only
    if not (csDesigning in ComponentState) then
    begin
      FAgent.ExecShellInfo := FShellExec;
      // Route agent log lines through the terminal so they are colored
      FPrevAgentOnLog := FAgent.OnLog;
      FAgent.OnLog := @HandleAgentLog;
    end;
  end;
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

procedure TCustomTermManager.HandleAgentChunk(Sender: TObject; const AText: string);
begin
  FFirstChunkSeen := True;
  // Close thinking block if open, this also resets color
  CloseThinking;
  WriteText(AText, False);
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
  SetColor(tcDim);
  WriteText(AText, True);
  SetColor(tcDefault);
  WriteLine('', True);
end;

procedure TCustomTermManager.HandleAgentFinish(Sender: TObject; AReason: TAgentFinishReason; const AAnswer, AErrorMsg: string);
var
  Streamed: boolean;
begin
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
end;

function TCustomTermManager.IsMetaCommand(const ACommand: string): boolean;
var
  Cmd: string;
  P: integer;
begin
  P := Pos(' ', ACommand);
  if P > 0 then
    Cmd := LowerCase(Copy(ACommand, 1, P - 1))
  else
    Cmd := LowerCase(ACommand);
  Result := (Cmd = 'cls') or (Cmd = 'clear') or (Cmd = 'exit') or (Cmd = 'quit') or (Cmd = 'help') or
    (Cmd = 'h') or (Cmd = '?') or (Cmd = 'config') or (Cmd = 'settings') or (Cmd = 'get') or (Cmd = 'history');
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
type
  TShellFamily = (sfCmd, sfUnix, sfPowerShell, sfUnknown);
const
  // Unix utilities that cmd.exe does not have
  UNIX_CMDS: array[0..15] of string = (
    'ls', 'cat', 'grep', 'head', 'tail', 'rm', 'cp', 'mv',
    'touch', 'which', 'chmod', 'chown', 'sudo', 'sed', 'awk', 'wc');
  // Windows utilities that Unix shells do not have
  WIN_CMDS: array[0..3] of string = (
    'findstr', 'cls', 'where', 'powershell');

// Returns the shell family inferred from the executable name
  function DetectShellFamily(const AShell: string): TShellFamily;
  var
    S: string;
  begin
    S := LowerCase(Trim(ExtractFileName(AShell)));
    if (S = '') or (S = 'cmd.exe') or (S = 'cmd') or (S = 'command.com') then
      Exit(sfCmd);
    if (S = 'powershell.exe') or (S = 'powershell') or (S = 'pwsh.exe') or (S = 'pwsh') then
      Exit(sfPowerShell);
    if (S = 'sh') or (S = 'bash') or (S = 'zsh') or (S = 'dash') or (S = 'fish') or (S = 'ksh') then
      Exit(sfUnix);
    Result := sfUnknown;
  end;

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
  if Assigned(FOnOutput) then
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
  InfoLabel, InfoCtx: string;
  HasContext: boolean;
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
end;

procedure TCustomTermManager.DoRoute(const ALine, APayload: string; var AKind: TTermInputKind; var AAllow: boolean);
begin
  if Assigned(FOnRoute) then
    FOnRoute(Self, ALine, APayload, AKind, AAllow);
end;

procedure TCustomTermManager.DoOutput(const AText: string; AIsStderr: boolean);
begin
  // Accumulate output of the currently running command for the shell log
  if FCapturing and FShellHistory.Enabled then
  begin
    if Length(FCaptureOutput) < FShellHistory.MaxOutputBytes * 2 then
      FCaptureOutput := FCaptureOutput + AText;
    if AIsStderr then
      FCaptureError := True;
  end;
  WriteText(AText, AIsStderr);
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
  CMD_BUILTINS: array[0..27] of string = (
    'dir', 'copy', 'del', 'erase', 'type', 'echo', 'set', 'md',
    'mkdir', 'rd', 'rmdir', 'ren', 'rename', 'move', 'ver', 'vol',
    'date', 'time', 'pause', 'call', 'goto', 'title', 'color',
    'prompt', 'start', 'pushd', 'popd', 'setlocal');
  {$ENDIF}
var
  I: integer;
  EnvPath: string;
begin
  {$IFDEF WINDOWS}
  for I := Low(CMD_BUILTINS) to High(CMD_BUILTINS) do
    if CMD_BUILTINS[I] = AName then
      Exit(True);
  {$ENDIF}
  EnvPath := SysUtils.GetEnvironmentVariable('PATH');
  Result := (FileSearch(AName, EnvPath) <> '')
  {$IFDEF WINDOWS}
    or (FileSearch(AName + '.exe', EnvPath) <> '')
    or (FileSearch(AName + '.bat', EnvPath) <> '')
    or (FileSearch(AName + '.cmd', EnvPath) <> '')
    or (FileSearch(AName + '.com', EnvPath) <> '')
  {$ENDIF}
  ;
end;

function TCustomTermManager.ClassifyLine(const ALine: string; out APayload: string): TTermInputKind;
var
  S, First: string;
  P: integer;
begin
  APayload := '';
  S := Trim(ALine);
  if S = '' then
    Exit(tikEmpty);

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
  P := Pos(' ', S);
  if P > 0 then
    First := LowerCase(Copy(S, 1, P - 1))
  else
    First := LowerCase(S);

  // Handle glued cd variants like cd.., cd\, cd/ the same way cmd.exe does
  if (Length(First) > 2) and (Copy(First, 1, 2) = 'cd') and (First[3] in ['.', PathDelim, '/']) then
  begin
    APayload := 'cd ' + Copy(S, 3, MaxInt);
    Exit(tikBuiltin);
  end;

  // Drive switch like "d:", "d:\", "d:\path" is a builtin, not an executable
  if (Length(First) >= 2) and (First[2] = ':') and (First[1] in ['a'..'z']) and ((Length(First) = 2) or
    (First[3] in [PathDelim, '/'])) then
  begin
    APayload := S;
    Exit(tikBuiltin);
  end;

  if FBuiltinCommands.IndexOf(First) >= 0 then
    Exit(tikBuiltin);

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
    // Clear agent conversation history, usage counters and shell log together with the screen
    if Assigned(FAgent) then
    begin
      FAgent.ClearHistory;
      FAgent.ResetUsage;
    end;
    FShellLog.Clear;
    ClearScreen;
  end
  else if Cmd = 'history' then
  begin
    for I := 0 to FHistory.Count - 1 do
      DoOutput(Format('%4d  %s%s', [I + 1, FHistory[I], LineEnding]), False);
  end
  else if (Cmd = 'help') or (Cmd = 'h') or (Cmd = '?') then
    HandleHelpCommand(Arg)
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

procedure TCustomTermManager.HandleHelpCommand(const AArg: string);
var
  Topic: string;
  BaseUrl, ModelName, MaxSteps, Streaming, Tools: string;

// Writes a command group row with a two-space indent
  procedure Group(const AName, AValue: string);
  var
    Pad: string;
  begin
    Pad := '  ' + AName;
    while Length(Pad) < 14 do
      Pad := Pad + ' ';
    DoOutput(Pad + AValue + LineEnding, False);
  end;

  // Writes a hint row with a label and a short description
  procedure Item(const ALabel, ADesc: string);
  var
    Pad: string;
  begin
    Pad := '  ' + ALabel;
    while Length(Pad) < 26 do
      Pad := Pad + ' ';
    DoOutput(Pad + ADesc + LineEnding, False);
  end;

  // Returns comma separated short tool names for display in help
  function BuildToolsList(AFeatures: TAgentFeatures): string;
  var
    Parts: TStringList;
  begin
    Parts := TStringList.Create;
    try
      if afFileTools in AFeatures then
        Parts.Add('filetools');
      if afExecCommand in AFeatures then
        Parts.Add('exec');
      if afGit in AFeatures then
        Parts.Add('git');
      if afInteractive in AFeatures then
        Parts.Add('interactive');
      if afFinish in AFeatures then
        Parts.Add('finish');
      if afWebTools in AFeatures then
        Parts.Add('web');
      if Parts.Count = 0 then
        Result := 'none'
      else
        Result := StringReplace(Parts.CommaText, ',', ', ', [rfReplaceAll]);
    finally
      Parts.Free;
    end;
  end;

begin
  Topic := LowerCase(Trim(AArg));
  if (Topic = 'agent') or (Topic = 'set') or (Topic = 'get') or (Topic = 'config') then
    DoOutput(FormatAgentHelp + LineEnding, False)
  else if (Topic = 'term') or (Topic = 'terminal') then
    DoOutput(FormatTermHelp + LineEnding, False)
  else
  begin
    DoOutput('Commands' + LineEnding, False);
    Group('shell', 'cd  pwd  cls  clear  history  exit  quit');
    Group('settings', 'set  get  config');
    Group('models', 'models  ollama');
    Group('help', 'help  help agent  help term  ?');
    DoOutput('' + LineEnding, False);

    if Assigned(FAgent) then
    begin
      if Assigned(FAgent.OllamaManager) then
        BaseUrl := FAgent.OllamaManager.BaseURL
      else
        BaseUrl := '(no manager)';
      ModelName := FAgent.ModelName;
      if ModelName = '' then
        ModelName := '(not selected)';
      if FAgent.MaxSteps > 0 then
        MaxSteps := IntToStr(FAgent.MaxSteps)
      else
        MaxSteps := '0 (unlimited)';
      if FAgent.Streaming then
        Streaming := 'on'
      else
        Streaming := 'off';
      Tools := BuildToolsList(FAgent.EnabledTools);

      DoOutput('Agent' + LineEnding, False);
      Group('baseurl', BaseUrl);
      Group('model', ModelName);
      Group('maxsteps', MaxSteps);
      Group('streaming', Streaming);
      Group('tools', Tools);
      DoOutput('' + LineEnding, False);

      Item('set <name> <value>', 'change a property');
      Item('get <name>', 'inspect a property');
      Item('config', 'full settings dump');
      Item('ollama help', 'model management commands');
      Item('', '');
    end
    else
    begin
      DoOutput('Agent  not attached, chat disabled' + LineEnding, False);
      DoOutput('' + LineEnding, False);
      Item('set baseurl <url>', 'server URL, e.g. http://localhost:11434');
      Item('set model <name>', 'select a model');
      Item('set maxsteps <n>', 'iteration limit, 0 = unlimited');
      Item('set streaming on|off', 'real time output');
      Item('set tools <list>', 'tool groups, "all" or "none"');
      DoOutput('' + LineEnding, False);
      Item('config', 'full settings dump');
      Item('ollama help', 'model management commands');
      Item('', '');
    end;
  end;
end;

procedure TCustomTermManager.HandleSetCommand(const AArg: string);
var
  P: integer;
  PropName, PropValue, ErrMsg: string;
begin
  if Trim(AArg) = '' then
  begin
    DoOutput('usage: set <name> <value>' + LineEnding, True);
    DoOutput('use "help agent" or "help term" for property lists' + LineEnding, True);
    Exit;
  end;
  P := Pos(' ', AArg);
  if P > 0 then
  begin
    PropName := Copy(AArg, 1, P - 1);
    PropValue := Trim(Copy(AArg, P + 1, MaxInt));
  end
  else
  begin
    PropName := Trim(AArg);
    PropValue := '';
  end;
  // term.* properties are handled locally, everything else goes to the agent
  if LowerCase(Copy(PropName, 1, 5)) = 'term.' then
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
    DoOutput('use "help agent" or "help term" for property lists' + LineEnding, True);
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
    DoOutput('error: unknown term property: ' + AName + ', use "help term"' + LineEnding, True);
    Exit;
  end;
  DoOutput('term.' + N + ' = ' + V + LineEnding, False);
end;

procedure TCustomTermManager.HandleTermGet(const AName: string);
var
  N: string;
  Val: string;
begin
  N := LowerCase(Trim(AName));
  if N = 'path' then
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
    DoOutput('error: unknown term property: ' + AName + ', use "help term"' + LineEnding, True);
    Exit;
  end;
  DoOutput('term.' + N + ' = ' + Val + LineEnding, False);
end;

function TCustomTermManager.FormatTermHelp: string;
var
  T: TStringList;

// Adds an aligned settings row with two-space indent
  procedure Row(const AName, ADesc: string);
  var
    Pad: string;
  begin
    Pad := '  ' + AName;
    while Length(Pad) < 24 do
      Pad := Pad + ' ';
    T.Add(Pad + ADesc);
  end;

begin
  T := TStringList.Create;
  try
    T.Add('Terminal settings  prefix "term."');
    T.Add('');
    Row('path', 'working directory');
    Row('shell', 'executable, e.g. cmd.exe or pwsh.exe');
    Row('showthinking', 'on|off, show agent reasoning text');
    Row('commandtimeout', 'ms, user command timeout, 0 = none');
    Row('maxcapturebytes', 'cap on captured output per command');
    Row('agentcommandtimeout', 'ms, agent exec_command timeout, 0 = none');
    T.Add('');
    Row('set term.<name> <value>', 'change a setting');
    Row('get term.<name>', 'inspect a setting');
    Row('config', 'full settings dump');
    T.Add('');
    T.Add('  example  set term.shell pwsh.exe');
    T.Add('');
    Result := T.Text;
  finally
    T.Free;
  end;
end;

function TCustomTermManager.FormatTermConfig: string;
var
  T: TStringList;

// Adds an aligned setting row
  procedure Row(const AName, AValue: string);
  var
    Pad: string;
  begin
    Pad := '  ' + AName;
    while Length(Pad) < 24 do
      Pad := Pad + ' ';
    T.Add(Pad + AValue);
  end;

begin
  T := TStringList.Create;
  try
    T.Add('Terminal');
    Row('path', GetEffectivePath);
    Row('shell', FShellExec);
    Row('showthinking', BoolToStr(FShowThinking, 'on', 'off'));
    Row('commandtimeout', IntToStr(FCommandTimeout));
    Row('maxcapturebytes', IntToStr(FMaxCaptureBytes));
    Row('agentcommandtimeout', IntToStr(FAgentCommandTimeout));
    Result := T.Text;
  finally
    T.Free;
  end;
end;

function TCustomTermManager.ReadSmallTextFile(const APath: string): string;
var
  Stream: TFileStream;
  Buf: TBytes = ();
  ReadCount: int64;
begin
  Result := '';
  if not FileExists(APath) then
    Exit;
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Buf, Stream.Size);
    if Length(Buf) > 0 then
    begin
      ReadCount := Stream.Read(Buf[0], Length(Buf));
      SetLength(Buf, ReadCount);
      Result := string(Buf);
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
    HandleOllamaHelp;
    Exit;
  end;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ' ';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Trim(AArg);
    if Parts.Count = 0 then
    begin
      HandleOllamaHelp;
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
    else if (Sub = 'version') or (Sub = '--version') or (Sub = '-v') then
      HandleOllamaVersion
    else if (Sub = 'help') or (Sub = '--help') or (Sub = '-h') then
      HandleOllamaHelp
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

procedure TCustomTermManager.HandleOllamaHelp;
var
  T: TStringList;

// Writes a section header with a leading blank line
  procedure Header(const AText: string);
  begin
    if T.Count > 0 then
      T.Add('');
    T.Add(AText);
  end;

  // Writes an aligned command row
  procedure Row(const ACmd, ADesc: string);
  var
    Pad: string;
  begin
    Pad := '  ' + ACmd;
    while Length(Pad) < 28 do
      Pad := Pad + ' ';
    T.Add(Pad + ADesc);
  end;

begin
  T := TStringList.Create;
  try
    T.Add('Ollama server management via the API, no external CLI');

    Header('List');
    Row('ollama list', 'installed models');
    Row('ollama ps', 'running models');
    Row('ollama show <model>', 'details as JSON');
    Row('ollama version', 'server version');

    Header('Models');
    Row('ollama pull <model>', 'download from registry');
    Row('ollama rm <model>', 'delete installed model');
    Row('ollama copy <src> <dst>', 'copy under a new name');
    Row('ollama create <name> <file>', 'build from a Modelfile');

    Header('Memory');
    Row('ollama load <model>', 'load into memory');
    Row('ollama unload <model>', 'unload from memory');
    Row('ollama stop <model>', 'same as unload');

    Header('Other');
    Row('ollama help', 'this help');

    T.Add('');
    T.Add('  Uses baseurl, never invokes the shell');
    T.Add('');

    DoOutput(T.Text, False);
  finally
    T.Free;
  end;
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
  {$IFDEF WINDOWS}
  InHandle: THandle;
  InMode: DWORD = 0;
  InModeSaved: boolean;
  {$ENDIF}
begin
  Result := -1;
  Buffer := Default(TTermBuffer);
  if ACommand = '' then
    Exit;
  FStdOutPending := '';
  FStdErrPending := '';

  // Drive switch "d:", "d:\", "d:\path" must run in-process
  if (Length(ACommand) >= 2) and (ACommand[2] = ':') and (ACommand[1] in ['a'..'z', 'A'..'Z']) and
    ((Length(ACommand) = 2) or (ACommand[3] in [PathDelim, '/'])) then
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
    if P > 0 then
      CommandName := Copy(CommandText, 1, P - 1)
    else
      CommandName := CommandText;
  end;

  CommandName := LowerCase(ExtractFileName(StringReplace(CommandName, '\', '/', [rfReplaceAll])));
  IsInteractive := Pos('|' + CommandName + '|', INTERACTIVE_COMMANDS) > 0;

  RawData := '';
  Process := TProcess.Create(nil);
  {$IFDEF WINDOWS}
  InModeSaved := False;
  {$ENDIF}
  try
    Process.Executable := FShellExec;
    {$IFDEF WINDOWS}
    Process.Parameters.Add('/c');
    Process.Parameters.Add('chcp 65001 > nul & ' + ACommand);
    {$ELSE}
    Process.Parameters.Add('-c');
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

    Result := Process.ExitStatus;
  finally
    {$IFDEF WINDOWS}
    if IsInteractive and InModeSaved then
      SetConsoleMode(InHandle, InMode);
    {$ENDIF}
    Process.Free;
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
    {$IFDEF WINDOWS}
    Process.Parameters.Add('/c');
    Process.Parameters.Add('chcp 65001 > nul & ' + ACommand);
    {$ELSE}
    Process.Parameters.Add('-c');
    Process.Parameters.Add(ACommand);
    {$ENDIF}
    Process.Options := [poUsePipes, poNoConsole];
    Process.CurrentDirectory := GetEffectivePath;
    Process.Execute;
    StartTime := Now;

    while Process.Running and not HitLimit do
    begin
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
  // Tag as UTF-8 without recoding so SetCodePage works on RawByteString
  Tagged := ALine;
  SetCodePage(Tagged, CP_UTF8, False);
  if (FHistory.Count > 0) and (FHistory[FHistory.Count - 1] = Tagged) then
    Exit;
  FHistory.Add(Tagged);
  while FHistory.Count > FHistoryMax do
    FHistory.Delete(0);
end;

procedure TCustomTermManager.Run;
var
  Line, Payload: string;
  Kind: TTermInputKind;
  Allow: boolean;
  CancelledShown: boolean;
  WaitShown: boolean;
  StartTick: QWord;
  {$IFDEF WINDOWS}
  InHandle: THandle;
  InMode: DWORD = 0;
  InModeSaved: boolean;
  {$ENDIF}
begin
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
  // Start with explicit default color so prompt and banner match scheme
  SetColor(tcDefault);
  // Print banner in welcome color, then restore default for prompt
  if FWelcome <> '' then
  begin
    SetColor(tcWelcome);
    DoOutput(FWelcome + LineEnding, False);
    SetColor(tcDefault);
  end;
  FRunning := True;
  FLastExitCode := 0;
  try
    while FRunning do
    begin
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
                FShellLog.Clear;
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
            FAgent.OnChunk := @HandleAgentChunk;
            FAgent.OnThinking := @HandleAgentThinking;
            FAgent.OnToolCall := @HandleAgentToolCall;
            FAgent.OnToolResult := @HandleAgentToolResult;
            FAgent.OnFinish := @HandleAgentFinish;
            FAgent.OnExecCommand := @HandleAgentExecCommand;
            FAgent.OnAskUser := @HandleAgentAskUser;
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
              FPrevAgentOnChunk := nil;
              FPrevAgentOnThinking := nil;
              FPrevAgentOnToolCall := nil;
              FPrevAgentOnToolResult := nil;
              FPrevAgentOnFinish := nil;
              FPrevAgentOnExecCommand := nil;
              FPrevAgentOnAskUser := nil;
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
  FRunning := False;
end;

{$IFDEF WINDOWS}

// Maps palette color to Windows foreground attribute bits
function ColorToAttr(AColor: TConsoleColor): Word;
const
  MAP: array[TConsoleColor] of Word = (
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
procedure SetConsoleColor(AAttr: Word);
var
  Handle: THandle;
begin
  Handle := GetStdHandle(STD_OUTPUT_HANDLE);
  SetConsoleTextAttribute(Handle, AAttr);
end;

procedure TCustomTermManager.SetColor(AColor: TTermColor);
var
  Attr: Word;

  // Combines background and foreground of a pair into a single attribute
  function PairAttr(const APair: TConsoleColorPair): Word;
  begin
    Result := (ColorToAttr(APair.Background) shl 4) or ColorToAttr(APair.Foreground);
  end;

begin
  if not FColorOutput then
    Exit;
  case AColor of
    tcDim: Attr := ColorToAttr(FColors.ThinkingText);
    tcWelcome: Attr := PairAttr(FColors.WelcomeBadge);
    tcThinkingBadge: Attr := PairAttr(FColors.ThinkingBadge);
    tcToolBadge: Attr := PairAttr(FColors.ToolBadge);
    tcErrorBadge: Attr := PairAttr(FColors.ErrorBadge);
    tcWarnBadge: Attr := PairAttr(FColors.WarnBadge);
    else
      Attr := ColorToAttr(FColors.DefaultText);
  end;
  SetConsoleColor(Attr);
end;

// Writes UTF-8 bytes directly to handle bypassing codepage conversion
procedure WriteUtf8ToHandle(AHandle: THandle; const ABytes: RawByteString);
var
  Mode: DWORD;
  Written: DWORD;
  Wide: UnicodeString;
  Ok: boolean;
begin
  if Length(ABytes) = 0 then
    Exit;
  Mode := 0;
  Written := 0;
  Ok := False;
  if (AHandle <> INVALID_HANDLE_VALUE) and GetConsoleMode(AHandle, Mode) then
  begin
    Wide := UTF8Decode(ABytes);
    if Length(Wide) > 0 then
      Ok := WriteConsoleW(AHandle, PWideChar(Wide), Length(Wide), Written, nil);
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

procedure ConGotoXY(X, Y: Integer);
var
  Coord: TCoord;
begin
  Coord.X := X - 1;
  Coord.Y := Y - 1;
  SetConsoleCursorPosition(GetStdHandle(STD_OUTPUT_HANDLE), Coord);
end;

function ConWhereY: Integer;
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
      FillConsoleOutputCharacter(GetStdHandle(STD_OUTPUT_HANDLE), ' ', Count,
        Info.dwCursorPosition, Written);
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
    if (AR.Event.KeyEvent.wVirtualKeyCode = VK_C) and
       ((AR.Event.KeyEvent.dwControlKeyState and
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
var
  Info: TConsoleCursorInfo;
begin
  Info := Default(TConsoleCursorInfo);
  if GetConsoleCursorInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info) then
  begin
    Info.bVisible := False;
    SetConsoleCursorInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info);
  end;
end;

// Restores console cursor visibility, used after redraw
procedure ShowConsoleCursor;
var
  Info: TConsoleCursorInfo;
begin
  Info := Default(TConsoleCursorInfo);
  if GetConsoleCursorInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info) then
  begin
    Info.bVisible := True;
    SetConsoleCursorInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info);
  end;
end;

function TCustomTermManager.ReadLine: string;
var
  Handle: THandle;
  Rec, NextRec: INPUT_RECORD;
  N: DWORD = 0;
  Line, PromptText: RawByteString;
  CursorPos, HistIndex, PromptRow: Integer;
  LastCursorRow: Integer;
  C: WideChar;
  Wide: UnicodeString;
  LastRedrawRows: Integer;
  HasMore, IsModifier, ShiftPressed, CtrlPressed: Boolean;
  SelAnchor, SelStart, SelEnd: Integer;
  HasSelection: Boolean;

  // Collects full UTF-8 sequence that conhost splits across key events
  procedure CollectBrokenUtf8(var AC: WideChar);
  const
    WAIT_TIMEOUT_MS = 100;
    MAX_CONSUMED = 64;
  var
    Raw: RawByteString;
    B, Nb, Attempts, TotalConsumed: Integer;
    Skip: boolean;
  begin
    B := Ord(AC) and $FF;
    if not (B in [$C2..$F4]) then
      Exit;
    Raw := AnsiChar(B);
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
        B := Ord(NextRec.Event.KeyEvent.UnicodeChar) and $FF;
        if (B < $80) or (B > $BF) then
        begin
          Skip := True;
          Break;
        end;
        ReadConsoleInput(Handle, NextRec, 1, N);
        Raw := Raw + AnsiChar(B);
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
  function SplitLines(const S: RawByteString): TStringList;
  var
    I, Start: Integer;
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

  procedure ClearSelection;
  begin
    SelAnchor := -1;
    HasSelection := False;
    SelStart := 0;
    SelEnd := 0;
  end;

  // Copies the selected byte range to the Windows clipboard as CF_UNICODETEXT
  procedure CopySelectionToClipboard;
  var
    SelText: RawByteString;
    SelWide: UnicodeString;
    hData: THandle;
    P: Pointer;
    Size, SelLen: SizeInt;
  begin
    if not HasSelection then
      Exit;
    SelText := Copy(Line, SelStart + 1, SelEnd - SelStart);
    SetCodePage(SelText, CP_UTF8, False);
    SelWide := UTF8Decode(SelText);
    SelLen := Length(SelWide);
    if not OpenClipboard(0) then
      Exit;
    try
      EmptyClipboard;
      Size := (SelLen + 1) * SizeOf(WideChar);
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
        Move(SelWide[1], P^, SelLen * SizeOf(WideChar));
      PWideChar(P)[SelLen] := #0;
      GlobalUnlock(hData);
      if SetClipboardData(CF_UNICODETEXT, hData) = 0 then
        GlobalFree(hData);
    finally
      CloseClipboard;
    end;
    end;

  // Reads clipboard text as a Unicode string, returns empty when clipboard has no text
  function ReadClipboardText: UnicodeString;
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
        Result := PWideChar(P);
      finally
        GlobalUnlock(hData);
      end;
    finally
      CloseClipboard;
    end;
  end;

  // Normalizes line endings to CRLF and inserts clipboard text at cursor
  procedure PasteText(const AText: UnicodeString);
  var
    Utf8: RawByteString;
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

  // Moves cursor vertically within the current input, returns False at edges
  function MoveCursorVertical(ADelta: Integer): Boolean;
  var
    I, Idx, LineStart, TargetStart, TargetLen, Col: Integer;
    Lines: TStringList;
  begin
    Result := False;
    if Pos(LineEnding, Line) = 0 then
      Exit;
    Lines := SplitLines(Line);
    try
      if Lines.Count < 2 then
        Exit;
      // Locate the current line by cursor byte position
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
      // Compute target line byte offset
      TargetStart := 0;
      for I := 0 to Idx + ADelta - 1 do
        Inc(TargetStart, Length(Lines[I]) + 2);
      TargetLen := Length(Lines[Idx + ADelta]);
      // Preserve column clamped to target line length
      Col := CursorPos - LineStart;
      if Col > TargetLen then
        Col := TargetLen;
      CursorPos := TargetStart + Col;
      Result := True;
    finally
      Lines.Free;
    end;
  end;

  // Inserts a UTF-8 char at the cursor, replacing the selection when active
  procedure InsertTypedChar(const AUtf8: RawByteString);
  var
    OldLen: Integer;
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
    I, J, J2, LenS, GlobalPos, LineStart: Integer;
    S: RawByteString;
    Lines: TStringList;
    Info: CONSOLE_SCREEN_BUFFER_INFO;
    NormalAttr, InvAttr: Word;
    IsSel, PrevIsSel: Boolean;
    CurRow, CurCol, NewRows: Integer;
    CursorSaved: Boolean;
  begin
    HideConsoleCursor;
    Info:=Default(CONSOLE_SCREEN_BUFFER_INFO);
    GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info);
    NormalAttr := Info.wAttributes;
    // Swap foreground and background to build the selection highlight
    InvAttr := ((NormalAttr and $0F) shl 4) or ((NormalAttr and $F0) shr 4);

    Lines := SplitLines(Line);
    try
      ConGotoXY(1, PromptRow);
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
          // Wipe stale content on the current row before moving on
          ConClearLineFromCursor;
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

      // Wipe stale content on the last visible row
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
      LastRedrawRows := NewRows;
    finally
      Lines.Free;
    end;

    ConGotoXY(CurCol, CurRow);
    ShowConsoleCursor;
    LastCursorRow := CurRow;
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
  Handle := GetStdHandle(STD_INPUT_HANDLE);
  // Drop input events accumulated while the agent was streaming, a paste
  // sent to a busy console would otherwise flood Line on the next read
  if (Handle <> 0) and (Handle <> INVALID_HANDLE_VALUE) then
  try
    FlushConsoleInputBuffer(Handle);
  except
    ; // Console may be detached
  end;
  ConWriteUtf8(PromptText);
  FLastCharWasNewLine := False;
  PromptRow := ConWhereY;
  LastRedrawRows := 1;
  LastCursorRow := PromptRow;

  while FRunning do
  begin
    if not ReadConsoleInput(Handle, Rec, 1, N) then
      Break;
    if Rec.EventType <> KEY_EVENT then
      Continue;
    if not Rec.Event.KeyEvent.bKeyDown then
      Continue;

    C := Rec.Event.KeyEvent.UnicodeChar;
    // Two conhost variants observed in the wild for UTF-8 input:
    //   high-byte wrapper ($FFxx) - raw byte sits in the low 8 bits
    //   plain byte       ($00xx) - UTF-8 lead byte sits in the low 8 bits
    // Both need CollectBrokenUtf8 to assemble the full sequence
    if (Ord(C) >= $FF00) or ((Ord(C) >= $C2) and (Ord(C) <= $F4)) then
      CollectBrokenUtf8(C);

    ShiftPressed := (Rec.Event.KeyEvent.dwControlKeyState and SHIFT_PRESSED) <> 0;
    CtrlPressed := (Rec.Event.KeyEvent.dwControlKeyState and
      (LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED)) <> 0;

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
              if (NextRec.EventType = KEY_EVENT) and
                (NextRec.Event.KeyEvent.wVirtualKeyCode = VK_RETURN) and
                (not NextRec.Event.KeyEvent.bKeyDown) then
                ReadConsoleInput(Handle, NextRec, 1, N);
          end;
          if IsModifier or HasMore then
          begin
            Line := Line + LineEnding;
            CursorPos := Length(Line);
            ClearSelection;
          end
          else
          begin
            ConWriteUtf8(LineEnding);
            FLastCharWasNewLine := True;
            Break;
          end;
        end;
      VK_BACK:
        begin
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
            if (Line[CursorPos + 1] = #13) and (CursorPos + 1 < Length(Line)) and
              (Line[CursorPos + 2] = #10) then
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
            if (CursorPos >= 2) and (Line[CursorPos] = #10) and
              (Line[CursorPos - 1] = #13) then
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
            if (CursorPos + 2 <= Length(Line)) and
              (Line[CursorPos + 1] = #13) and (Line[CursorPos + 2] = #10) then
              Inc(CursorPos, 2)
            else
              CursorPos := Utf8NextPos(Line, CursorPos + 1) - 1;
          end;
          if ShiftPressed then
            UpdateSelection;
        end;
      VK_HOME:
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
      VK_END:
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
      VK_UP:
        begin
          ClearSelection;
          // When a single logical line is wrapped by the console, first jump
          // to the start of that line so typed text is not lost to history
          if (Length(Line) > 0) and (Pos(LineEnding, Line) = 0) and (LastCursorRow > PromptRow) then
            CursorPos := FindLineStart(CursorPos)
          // Move within multiline input first, fall back to history at top
          else if not MoveCursorVertical(-1) then
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
              CursorPos := Length(Line);
            end;
          end;
        end;
      VK_DOWN:
        begin
          ClearSelection;
          // Move within multiline input first, fall back to history at bottom
          if not MoveCursorVertical(1) then
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
          end;
        end;
      VK_ESCAPE:
        begin
          Line := '';
          CursorPos := 0;
          ClearSelection;
        end;
      VK_V:
        if CtrlPressed then
          PasteText(ReadClipboardText)
        else if Ord(C) >= 32 then
          InsertTypedChar(WideCharToUtf8(C));
      VK_A:
        if CtrlPressed then
        begin
          SelAnchor := 0;
          CursorPos := Length(Line);
          UpdateSelection;
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
end;

{$ELSE}

procedure TCustomTermManager.SetColor(AColor: TTermColor);
begin
  // No-op on non-Windows, override to emit ANSI escape sequences
  ;
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
  S: string;
begin
  Result := '';
  Write(GetPromptText);
  if not FRunning then
    Exit;
  ReadLn(S);
  Result := S;
  AddToHistory(S);
end;

{$ENDIF}

end.
