//-----------------------------------------------------------------------------------
//  OllamaKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit OllamaAgent;

{$mode objfpc}{$H+}

{$IFDEF DEBUG}
{$R+}{$Q+}
{$ENDIF}

interface

uses
  Classes, SysUtils, Controls, FileUtil, fpjson, jsonparser, StringHelper, OllamaManager, Network;

type
  // Feature toggles controlled by the Features set property
  TAgentFeature = (
    // Enable built-in file tools: read, write, edit, delete, move, copy, list, find, grep
    afFileTools,
    // Enable exec_command tool, host runs the shell command via OnExecCommand
    afExecCommand,
    // Enable git tools: status, diff, log, commit, all executed through OnExecCommand
    afGit,
    // Enable ask_user tool, host shows the question and returns the answer via OnAskUser
    afInteractive,
    // Enable finish tool, model can declare the task complete and return a final message
    afFinish,
    // Enable web tools: web_fetch and web_search, GET only, SSRF safe by default
    afWebTools
    );
  TAgentFeatures = set of TAgentFeature;

  // Operation kind passed to OnRoute before each action
  TAgentOperation = (aoChat, aoToolCall);

  // Terminal reason reported by OnFinish
  TAgentFinishReason = (afrSuccess, afrMaxSteps, afrCancelled, afrError, afrModelNotSet);

  TAgentRouteEvent = procedure(Sender: TObject; AOp: TAgentOperation; const APayload: string; var AAllow: boolean) of object;
  TAgentChunkEvent = procedure(Sender: TObject; const AText: string) of object;
  TAgentThinkingEvent = procedure(Sender: TObject; const AText: string) of object;
  TAgentToolCallEvent = procedure(Sender: TObject; const AName, AArgsJson: string) of object;
  TAgentToolResultEvent = procedure(Sender: TObject; const AName, AResult: string) of object;
  TAgentExecCommandEvent = procedure(Sender: TObject; const ACommand: string; var AResult: string; var AAllow: boolean) of object;
  TAgentFinishEvent = procedure(Sender: TObject; AReason: TAgentFinishReason; const AAnswer, AErrorMsg: string) of object;
  TAgentToolExecuteEvent = procedure(Sender: TObject; const AArgsJson: string; var AResult: string) of object;
  TAgentAskUserEvent = procedure(Sender: TObject; const AQuestion: string; var AAnswer: string; var AAllow: boolean) of object;
  TAgentLogEvent = procedure(Sender: TObject; const AText: string) of object;

type
  TCustomOllamaAgent = class;

  // Web access options used by web_fetch and web_search tools
  TAgentWebOptions = class(TPersistent)
  private
    FSearchUrl: string;
    FUserAgent: string;
    FRequestTimeout: integer;
    FMaxResponseBytes: integer;
    FStripHtml: boolean;
    FBlockLocalhost: boolean;
    FBlockPrivateIPs: boolean;
    FAllowedHosts: TStringList;
    procedure SetAllowedHosts(const AValue: TStringList);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Assign(Source: TPersistent); override;
  published
    // URL template for web_search, {query} is replaced with url-encoded text
    property SearchUrl: string read FSearchUrl write FSearchUrl;
    // User-Agent header sent with requests, use browser UA to avoid bot blocking
    property UserAgent: string read FUserAgent write FUserAgent;
    // Timeout in milliseconds for each web request
    property RequestTimeout: integer read FRequestTimeout write FRequestTimeout default 15000;
    // Maximum response body size in bytes, longer bodies are truncated
    property MaxResponseBytes: integer read FMaxResponseBytes write FMaxResponseBytes default 524288;
    // Strip HTML tags and entities before returning content to the model
    property StripHtml: boolean read FStripHtml write FStripHtml default True;
    // Block localhost, 127.0.0.1 and ::1 addresses
    property BlockLocalhost: boolean read FBlockLocalhost write FBlockLocalhost default True;
    // Block RFC1918 and link-local private IPv4 addresses
    property BlockPrivateIPs: boolean read FBlockPrivateIPs write FBlockPrivateIPs default True;
    // Host whitelist, when empty any host is allowed subject to blocks above
    property AllowedHosts: TStringList read FAllowedHosts write SetAllowedHosts;
  end;

  // User-defined tool registered in the Tools collection
  TAgentTool = class(TCollectionItem)
  private
    FName: string;
    FDescription: TCaption;
    FParametersJson: TCaption;
    FOnExecute: TAgentToolExecuteEvent;
  published
    // Function name exposed to the LLM, must be unique
    property Name: string read FName write FName;
    // Human-readable description shown to the LLM
    property Description: TCaption read FDescription write FDescription;
    // JSON schema for the parameters object, must be valid JSON
    property ParametersJson: TCaption read FParametersJson write FParametersJson;
    // Fired when the LLM calls this tool, host fills AResult
    property OnExecute: TAgentToolExecuteEvent read FOnExecute write FOnExecute;
  end;

  // Collection of user-defined tools
  TAgentTools = class(TCollection)
  private
    FOwner: TCustomOllamaAgent;
    function GetItem(AIndex: integer): TAgentTool;
    procedure SetItem(AIndex: integer; const AValue: TAgentTool);
  protected
    function GetOwner: TPersistent; override;
  public
    constructor Create(AOwner: TCustomOllamaAgent);
    function Add: TAgentTool;
    property Items[AIndex: integer]: TAgentTool read GetItem write SetItem; default;
  end;

  // LLM agent with tool-calling loop, independent of any terminal component
  TCustomOllamaAgent = class(TComponent)
  private
    FOllamaManager: TOllamaManager;
    FModelName: string;
    FSystemPrompt: TCaption;
    FMaxSteps: integer;
    FRequestTimeout: integer;
    FFeatures: TAgentFeatures;
    FStreaming: boolean;
    FRootPath: string;
    FTools: TAgentTools;
    FWebOptions: TAgentWebOptions;
    FKeepHistory: boolean;
    FHistory: string;
    FDone: boolean;
    FCancelled: boolean;
    FFinalAnswer: string;
    // When True, the agent logs every step and event to stderr
    FLog: boolean;
    // When True, tool result previews are emitted through the log channel
    FLogToolResult: boolean;
    // Host handler for log lines, nil falls back to stderr
    FOnLog: TAgentLogEvent;
    // Prompt plus generated tokens reported by the last step
    FContextUsed: integer;
    // Configured context window size in tokens, 0 when unknown
    FContextTotal: integer;
    FOnRoute: TAgentRouteEvent;
    FOnChunk: TAgentChunkEvent;
    FOnThinking: TAgentThinkingEvent;
    FOnToolCall: TAgentToolCallEvent;
    FOnToolResult: TAgentToolResultEvent;
    FOnExecCommand: TAgentExecCommandEvent;
    FOnAskUser: TAgentAskUserEvent;
    FOnFinish: TAgentFinishEvent;
    // Optional context prepended to the next user message, cleared after use
    FContextPrelude: string;
    // Cached capabilities per model name, "1" means tools supported
    FCapabilitiesCache: TStringList;
    // Shell executable that runs exec_command, empty falls back to platform default
    FExecShellInfo: string;
    // Load workspace root AGENTS.md into the system prompt
    FLoadAgentsMd: boolean;
    // File name for project instruction files, standard is AGENTS.md
    FAgentsFileName: string;
    // Allow file tools to reach any path on the system, disable to sandbox to RootPath
    FAllowAccessToSystem: boolean;
    // Reject access to well-known secret files like .ssh/, .env, *.key
    FBlockSensitiveFiles: boolean;
    procedure SetOllamaManager(const AValue: TOllamaManager);
    procedure SetTools(const AValue: TAgentTools);
    procedure SetWebOptions(const AValue: TAgentWebOptions);
    function GetRootPath: string;
    procedure SetRootPath(const AValue: string);
    function GetHistory: string;
    procedure SetHistory(const AValue: string);
    function GetContextPercent: integer;
    function GetContextUsedKb: integer;
    function GetContextTotalKb: integer;
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    // Returns absolute root path for sandboxed file tools
    function GetEffectiveRootPath: string; virtual;
    // Resolves a relative path inside RootPath, returns '' when escaping
    function SafePath(const ARelPath: string): string; virtual;
    // Builds the JSON error for a rejected path, depends on sandbox mode
    function SafePathError: string; virtual;
    // Unified URL check used by web_fetch and web_search
    function CheckUrlSafety(const AUrl: string; out AErrorMsg: string): boolean; virtual;
    // Builds a file-not-found error with similar names from the same directory
    function BuildFileNotFoundError(const AFullPath, ARelPath: string): string; virtual;
    // Built-in tool implementations, invoked from DispatchTool
    function DoReadFile(AArgs: TJSONObject): string; virtual;
    // Shows first and last lines of a file with a gap marker
    function DoReadFilePreview(AArgs: TJSONObject): string; virtual;
    function DoWriteFile(AArgs: TJSONObject): string; virtual;
    function DoListFiles(AArgs: TJSONObject): string; virtual;
    function DoSearchText(AArgs: TJSONObject): string; virtual;
    function DoReadFileLines(AArgs: TJSONObject): string; virtual;
    function DoEditFile(AArgs: TJSONObject): string; virtual;
    function DoDeleteFile(AArgs: TJSONObject): string; virtual;
    function DoMoveFile(AArgs: TJSONObject): string; virtual;
    function DoCopyFile(AArgs: TJSONObject): string; virtual;
    function DoFileInfo(AArgs: TJSONObject): string; virtual;
    function DoCreateDirectory(AArgs: TJSONObject): string; virtual;
    function DoFindFiles(AArgs: TJSONObject): string; virtual;
    function DoGrep(AArgs: TJSONObject): string; virtual;
    // Reads the nearest AGENTS.md walking up from the given path
    function DoReadAgentsMd(AArgs: TJSONObject): string; virtual;
    // Git tools delegate to OnExecCommand, host runs git in its own shell
    function DoGitCommand(const AFullCommand: string): string; virtual;
    function DoGitStatus(AArgs: TJSONObject): string; virtual;
    function DoGitDiff(AArgs: TJSONObject): string; virtual;
    function DoGitLog(AArgs: TJSONObject): string; virtual;
    function DoGitCommit(AArgs: TJSONObject): string; virtual;
    // Ask user delegates to OnAskUser, host shows the question
    function DoAskUser(AArgs: TJSONObject): string; virtual;
    // Web tools, GET only, subject to WebOptions restrictions
    function DoWebFetchInternal(const AUrl: string; out AContent, AErrorMsg: string): boolean; virtual;
    function DoWebFetch(AArgs: TJSONObject): string; virtual;
    function DoWebSearch(AArgs: TJSONObject): string; virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Starts the agent in a background thread, returns immediately
    procedure RunAsync(const AText: string);
    // Runs synchronously, returns the final answer
    function Run(const AText: string): string;
    // Requests cancellation, effective between steps and inside streaming
    procedure Cancel;
    // Clears accumulated history
    procedure ClearHistory;
    // Dispatches one tool call, called by the worker thread
    function DispatchTool(const AName, AArgsJson: string): string; virtual;
    // Builds an actionable error listing available tools and hints
    function BuildUnknownToolError(const AName: string): string; virtual;
    // Returns False when the model definitely lacks tool support
    function ModelSupportsTools(out AErrorMsg: string): boolean;
    // Compresses a JSON array of messages into a short summary string
    function SummarizeMessages(const AMessagesJson: string): string;
    // Builds JSON schema array with all available tools
    function BuildToolsSchemaJson: string; virtual;
    // Returns comma-separated list of tool names for diagnostics
    function BuildToolsNames: string; virtual;
    // Writes a diagnostic line to stderr when Log is enabled
    procedure LogLine(const AText: string); virtual;
    // Emits a log line through OnLog or stderr, no Log flag check
    procedure DoLog(const AText: string); virtual;
    // Emits a truncated tool result preview when LogToolResult is enabled
    procedure EmitToolResult(const AName, AResult: string); virtual;
    // Resolves placeholders in SystemPrompt using current values
    function BuildSystemPrompt: string; virtual;
    // Resolves model context window size and updates ContextTotal
    procedure RefreshContextInfo;
    // Resets usage counters in the manager and this agent
    procedure ResetUsage;

    property Done: boolean read FDone;
    property FinalAnswer: string read FFinalAnswer;
    property ContextPrelude: string read FContextPrelude write FContextPrelude;
    property ExecShellInfo: string read FExecShellInfo write FExecShellInfo;
    property LoadAgentsMd: boolean read FLoadAgentsMd write FLoadAgentsMd default True;
    property AgentsFileName: string read FAgentsFileName write FAgentsFileName;
    property AllowAccessToSystem: boolean read FAllowAccessToSystem write FAllowAccessToSystem default True;
    property BlockSensitiveFiles: boolean read FBlockSensitiveFiles write FBlockSensitiveFiles default True;
    property History: string read GetHistory write SetHistory;
    property ContextUsed: integer read FContextUsed;
    property ContextTotal: integer read FContextTotal write FContextTotal;
    property ContextPercent: integer read GetContextPercent;
    property ContextUsedKb: integer read GetContextUsedKb;
    property ContextTotalKb: integer read GetContextTotalKb;
    property OllamaManager: TOllamaManager read FOllamaManager write SetOllamaManager;
    property ModelName: string read FModelName write FModelName;
    property SystemPrompt: TCaption read FSystemPrompt write FSystemPrompt;
    property MaxSteps: integer read FMaxSteps write FMaxSteps default 20;
    property RequestTimeout: integer read FRequestTimeout write FRequestTimeout default 0;
    property EnabledTools: TAgentFeatures read FFeatures write FFeatures default [afFileTools];
    property Streaming: boolean read FStreaming write FStreaming default True;
    property RootPath: string read GetRootPath write SetRootPath;
    property Tools: TAgentTools read FTools write SetTools;
    property WebOptions: TAgentWebOptions read FWebOptions write SetWebOptions;
    property KeepHistory: boolean read FKeepHistory write FKeepHistory default False;
    property Log: boolean read FLog write FLog default False;
    property LogToolResult: boolean read FLogToolResult write FLogToolResult default True;
    property OnLog: TAgentLogEvent read FOnLog write FOnLog;
    property OnRoute: TAgentRouteEvent read FOnRoute write FOnRoute;
    property OnChunk: TAgentChunkEvent read FOnChunk write FOnChunk;
    property OnThinking: TAgentThinkingEvent read FOnThinking write FOnThinking;
    property OnToolCall: TAgentToolCallEvent read FOnToolCall write FOnToolCall;
    property OnToolResult: TAgentToolResultEvent read FOnToolResult write FOnToolResult;
    property OnExecCommand: TAgentExecCommandEvent read FOnExecCommand write FOnExecCommand;
    property OnAskUser: TAgentAskUserEvent read FOnAskUser write FOnAskUser;
    property OnFinish: TAgentFinishEvent read FOnFinish write FOnFinish;
  end;

  // Published version of the agent that exposes all properties in the IDE
  TOllamaAgent = class(TCustomOllamaAgent)
  published
    // Ollama API client used for chat requests
    property OllamaManager;
    // Model name passed to Ollama, e.g. qwen2.5-coder:7b
    property ModelName;
    // System message sent before the conversation
    property SystemPrompt;
    // Maximum number of agent iterations, zero means unlimited
    property MaxSteps;
    // Per-request timeout in ms, 0 means use OllamaManager default
    property RequestTimeout;
    // Enable streaming of content and thinking chunks in real time
    property Streaming;
    // Tool groups enabled for this agent, empty means chat only
    property EnabledTools;
    // Sandbox directory for file tools, empty means process cwd
    property RootPath;
    // Collection of user-defined tools
    property Tools;
    // Web tools configuration, expand to adjust search URL, timeout, whitelist
    property WebOptions;
    // When True, messages persist between RunAsync calls
    property KeepHistory;
    // Load workspace root AGENTS.md into the system prompt
    property LoadAgentsMd;
    // Instruction file name, looked up in the root and in subdirectories
    property AgentsFileName;
    // When False, file tools are sandboxed to RootPath, absolute paths are rejected
    property AllowAccessToSystem;
    // Deny access to well-known secret files like .ssh/, .env, *.key, id_rsa
    property BlockSensitiveFiles;
    // When True, the agent logs every step and event to stderr
    property Log;
    // Emit tool result previews through the log channel, truncated to 500 chars
    property LogToolResult;
    // Receives every log line, host may color or redirect it
    property OnLog;
    // Fired before chat step and each tool call, host may reject
    property OnRoute;
    // Fired for every streamed text chunk from the model
    property OnChunk;
    // Fired for every thinking chunk from the model
    property OnThinking;
    // Fired when the LLM requests a tool, after host approval
    property OnToolCall;
    // Fired with the tool result before it is sent back to the model
    property OnToolResult;
    // Fired for exec_command tool, host executes and returns the output
    property OnExecCommand;
    // Fired for ask_user tool, host shows the question and returns the answer
    property OnAskUser;
    // Fired once when the run terminates for any reason
    property OnFinish;
  end;

implementation

uses
  Math, RegExpr, Masks;

// Returns display name for an agent operation kind
function AgentOpName(AOp: TAgentOperation): string;
begin
  case AOp of
    aoChat: Result := 'Chat';
    aoToolCall: Result := 'ToolCall';
    else
      Result := 'Unknown';
  end;
end;

// Returns display name for a finish reason
function AgentFinishReasonName(AReason: TAgentFinishReason): string;
begin
  case AReason of
    afrSuccess: Result := 'Success';
    afrMaxSteps: Result := 'MaxSteps';
    afrCancelled: Result := 'Cancelled';
    afrError: Result := 'Error';
    afrModelNotSet: Result := 'ModelNotSet';
    else
      Result := 'Unknown';
  end;
end;

// Returns True when the named tool is read-only and safe to run concurrently
function IsParallelSafeTool(const AName: string): boolean;
begin
  Result := (AName = 'read_file') or (AName = 'read_file_preview') or (AName = 'read_file_lines') or
    (AName = 'list_files') or (AName = 'find_files') or (AName = 'grep') or (AName = 'search_text') or
    (AName = 'file_info') or (AName = 'read_agents_md') or (AName = 'web_fetch') or (AName = 'web_search');
end;

// Returns path relative to ARoot for display, or full path when outside root
function RelativeToRoot(const ARoot, APath: string): string;
begin
  if Pos(LowerCase(IncludeTrailingPathDelimiter(ARoot)), LowerCase(APath)) = 1 then
    Result := Copy(APath, Length(ARoot) + 1, MaxInt)
  else
    Result := APath;
end;

// Strict UTF-8 byte validation used by feAuto detection
function TryDecodeUTF8Strict(const ARaw: TBytes; out AText: unicodestring): boolean;
var
  I: integer;
begin
  Result := False;
  AText := '';
  I := 0;
  while I < Length(ARaw) do
  begin
    if ARaw[I] < $80 then
      Inc(I)
    else if (ARaw[I] >= $C2) and (ARaw[I] <= $DF) then
    begin
      if (I + 1 >= Length(ARaw)) or (ARaw[I + 1] and $C0 <> $80) then Exit;
      Inc(I, 2);
    end
    else if (ARaw[I] >= $E0) and (ARaw[I] <= $EF) then
    begin
      if (I + 2 >= Length(ARaw)) or (ARaw[I + 1] and $C0 <> $80) or (ARaw[I + 2] and $C0 <> $80) then Exit;
      Inc(I, 3);
    end
    else if (ARaw[I] >= $F0) and (ARaw[I] <= $F4) then
    begin
      if (I + 3 >= Length(ARaw)) or (ARaw[I + 1] and $C0 <> $80) or (ARaw[I + 2] and $C0 <> $80) or (ARaw[I + 3] and $C0 <> $80) then
        Exit;
      Inc(I, 4);
    end
    else
      Exit;
  end;
  try
    AText := TEncoding.UTF8.GetString(ARaw);
    Result := True;
  except
    Result := False;
  end;
end;

type
  // Encoding selector for ReadTextFileSafe
  TFileEncoding = (feAuto, feUTF8, feANSI, feUTF16LE, feUTF16BE);

function ReadTextFileSafe(const APath: string; out AContent: string; AEncoding: TFileEncoding; AStartLine: integer;
  AEndLine: integer; AMaxBytes: int64; out ATotalLines: integer; out ABytesRead: int64; out AFileSize: int64): boolean;
var
  Stream: TFileStream;
  RawBytes: TBytes;
  Enc: TEncoding;
  UText: unicodestring;
  UResult: unicodestring;
  Probe: unicodestring;
  Lines: TStringList;
  I: integer;
begin
  Result := False;
  AContent := '';
  ATotalLines := 0;
  ABytesRead := 0;
  AFileSize := 0;
  RawBytes := nil;
  Enc := nil;
  UText := '';
  UResult := '';
  Probe := '';

  if not FileExists(APath) then
    Exit;

  // Read raw bytes from disk, capped by AMaxBytes when set
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      AFileSize := Stream.Size;
      if (AMaxBytes > 0) and (AMaxBytes < AFileSize) then
        SetLength(RawBytes, AMaxBytes)
      else
        SetLength(RawBytes, AFileSize);
      if Length(RawBytes) > 0 then
      begin
        Stream.ReadBuffer(RawBytes[0], Length(RawBytes));
        ABytesRead := Length(RawBytes);
      end
      else
        ABytesRead := 0;
      SetLength(RawBytes, ABytesRead);
    finally
      Stream.Free;
    end;
  except
    Exit;
  end;

  // Explicit encoding
  case AEncoding of
    feUTF8: Enc := TEncoding.UTF8;
    feANSI: Enc := TEncoding.ANSI;
    feUTF16LE: Enc := TEncoding.Unicode;
    feUTF16BE: Enc := TEncoding.BigEndianUnicode;
    else
      ;
  end;

  // BOM detection overrides auto mode
  if (Enc = nil) and (Length(RawBytes) >= 3) and (RawBytes[0] = $EF) and (RawBytes[1] = $BB) and (RawBytes[2] = $BF) then
    Enc := TEncoding.UTF8
  else if (Enc = nil) and (Length(RawBytes) >= 2) and (RawBytes[0] = $FF) and (RawBytes[1] = $FE) then
    Enc := TEncoding.Unicode
  else if (Enc = nil) and (Length(RawBytes) >= 2) and (RawBytes[0] = $FE) and (RawBytes[1] = $FF) then
    Enc := TEncoding.BigEndianUnicode;

  // Auto: strict UTF-8 check, then fall back to system ANSI
  if Enc = nil then
  begin
    if TryDecodeUTF8Strict(RawBytes, Probe) then
    begin
      Enc := TEncoding.UTF8;
      UText := Probe;
    end
    else
      Enc := TEncoding.ANSI;
  end;

  if UText = '' then
  begin
    try
      UText := Enc.GetString(RawBytes);
    except
      Exit;
    end;
  end;

  // Strip a leading BOM from the decoded text
  if (Length(UText) > 0) and (UText[1] = #$FEFF) then
    Delete(UText, 1, 1);

  Lines := TStringList.Create;
  try
    Lines.Text := UTF8Encode(UText);
    ATotalLines := Lines.Count;

    if (AStartLine >= 1) or (AEndLine >= 1) then
    begin
      if AStartLine < 1 then
        AStartLine := 1;
      if (AEndLine < 0) or (AEndLine > ATotalLines) then
        AEndLine := ATotalLines;
      UResult := '';
      for I := AStartLine - 1 to AEndLine - 1 do
      begin
        if I > AStartLine - 1 then
          UResult := UResult + #13#10;
        UResult := UResult + UTF8Decode(Lines[I]);
      end;
    end
    else
      UResult := UText;
  finally
    Lines.Free;
  end;

  // Encode as UTF-8 bytes into the AnsiString result
  AContent := string(UTF8Encode(UResult));
  SetCodePage(rawbytestring(AContent), CP_UTF8, False);

  Result := True;
end;

function ReadTextFileSafe(const APath: string; out AContent: string; AEncoding: TFileEncoding): boolean;
var
  TotalLines: integer;
  BytesRead: int64;
  FileSize: int64;
begin
  Result := ReadTextFileSafe(APath, AContent, AEncoding, 0, -1, 0, TotalLines, BytesRead, FileSize);
end;

function ReadTextFileSafe(const APath: string; out AContent: string): boolean;
begin
  Result := ReadTextFileSafe(APath, AContent, feAuto);
end;

// Writes UTF-8 text to file, creates parent directories
function WriteTextFileSafe(const APath, AContent: string): boolean;
var
  Stream: TFileStream;
  Bytes: TBytes;
begin
  Result := False;
  ForceDirectories(ExtractFileDir(APath));
  try
    Stream := TFileStream.Create(APath, fmCreate);
    try
      Bytes := TBytes(AContent);
      if Length(Bytes) > 0 then
        Stream.Write(Bytes[0], Length(Bytes));
      Result := True;
    finally
      Stream.Free;
    end;
  except
    Result := False;
  end;
end;

// Returns True for drive-absolute (D:...) or root-absolute (\... or /...) paths
function IsPathAbsolute(const APath: string): boolean;
begin
  {$IFDEF WINDOWS}
  if (Length(APath) >= 2) and (APath[2] = ':') then
    Exit(True);
  {$ENDIF}
  Result := (Length(APath) >= 1) and (APath[1] in [PathDelim, '/']);
end;

// Returns position of ASubstr in AText starting at AStart, or 0 when not found
function PosFrom(const ASubstr, AText: string; AStart: integer): integer;
var
  Partial: string;
begin
  if AStart < 1 then
    AStart := 1;
  if AStart > Length(AText) then
    Exit(0);
  Partial := Copy(AText, AStart, MaxInt);
  Result := Pos(ASubstr, Partial);
  if Result > 0 then
    Result := Result + AStart - 1;
end;

// Percent-encodes a string for use in URL query values
function UrlEncode(const S: string): string;
const
  HEX = '0123456789ABCDEF';
var
  I: integer;
  C: byte;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := Ord(S[I]);
    if ((C >= Ord('a')) and (C <= Ord('z'))) or ((C >= Ord('A')) and (C <= Ord('Z'))) or
      ((C >= Ord('0')) and (C <= Ord('9'))) or (C in [Ord('-'), Ord('_'), Ord('.'), Ord('~')]) then
      Result := Result + Chr(C)
    else if C = Ord(' ') then
      Result := Result + '+'
    else
      Result := Result + '%' + HEX[(C shr 4) + 1] + HEX[(C and $F) + 1];
  end;
end;

// Parses an IPv4 dotted quad, returns False on malformed input
function ParseIPv4(const AHost: string; out O1, O2, O3, O4: integer): boolean;
var
  Parts: array[0..3] of integer;
  S: string;
  P, I: integer;
begin
  Result := False;
  O1 := -1;
  O2 := -1;
  O3 := -1;
  O4 := -1;
  S := AHost;
  for I := 0 to 3 do
  begin
    P := Pos('.', S);
    if P = 0 then
    begin
      if I <> 3 then
        Exit;
      Parts[I] := StrToIntDef(S, -1);
    end
    else
    begin
      if I = 3 then
        Exit;
      Parts[I] := StrToIntDef(Copy(S, 1, P - 1), -1);
      S := Copy(S, P + 1, MaxInt);
    end;
    if (Parts[I] < 0) or (Parts[I] > 255) then
      Exit;
  end;
  O1 := Parts[0];
  O2 := Parts[1];
  O3 := Parts[2];
  O4 := Parts[3];
  Result := True;
end;

// Returns True for localhost names, loopback and unspecified addresses
function IsLocalhostAddress(const AHost: string): boolean;
var
  H: string;
  O1, O2, O3, O4: integer;
begin
  Result := False;
  H := LowerCase(Trim(AHost));
  if (H = 'localhost') or (H = 'localhost.localdomain') then
    Exit(True);
  // IPv6 loopback and unspecified
  if (H = '::1') or (H = '::') then
    Exit(True);
  // IPv4-mapped IPv6 pointing at loopback
  if Copy(H, 1, 7) = '::ffff:' then
    Exit(IsLocalhostAddress(Copy(H, 8, MaxInt)));
  // IPv4 loopback and "this network"
  if ParseIPv4(H, O1, O2, O3, O4) then
    if (O1 = 0) or (O1 = 127) then
      Exit(True);
end;

// Returns True for RFC1918, CGNAT, link-local, multicast and reserved ranges
function IsPrivateAddress(const AHost: string): boolean;
var
  H, FirstWord, Embedded: string;
  O1, O2, O3, O4: integer;
  P: integer;
begin
  Result := False;
  H := LowerCase(Trim(AHost));
  // Strip IPv6 zone ID like %eth0
  P := Pos('%', H);
  if P > 0 then
    H := Copy(H, 1, P - 1);
  // IPv4-mapped IPv6, recurse on the embedded IPv4
  if Copy(H, 1, 7) = '::ffff:' then
  begin
    Embedded := Copy(H, 8, MaxInt);
    Exit(IsPrivateAddress(Embedded));
  end;
  if ParseIPv4(H, O1, O2, O3, O4) then
  begin
    if O1 = 10 then
      Exit(True);
    // 100.64.0.0/10 carrier-grade NAT
    if (O1 = 100) and (O2 >= 64) and (O2 <= 127) then
      Exit(True);
    // 169.254.0.0/16 link-local
    if (O1 = 169) and (O2 = 254) then
      Exit(True);
    // 172.16.0.0/12 private
    if (O1 = 172) and (O2 >= 16) and (O2 <= 31) then
      Exit(True);
    // 192.168.0.0/16 private
    if (O1 = 192) and (O2 = 168) then
      Exit(True);
    // 198.18.0.0/15 benchmark
    if (O1 = 198) and (O2 >= 18) and (O2 <= 19) then
      Exit(True);
    // 224.0.0.0/4 multicast
    if (O1 >= 224) and (O1 <= 239) then
      Exit(True);
    // 240.0.0.0/4 reserved, includes 255.255.255.255
    if O1 >= 240 then
      Exit(True);
    Exit;
  end;
  // IPv6: take the first hex group
  P := Pos(':', H);
  if P > 0 then
    FirstWord := Copy(H, 1, P - 1)
  else
    FirstWord := H;
  if FirstWord = '' then
    Exit;
  // Link-local fe80::/10, first group fe80 to febf
  if (Length(FirstWord) >= 3) and (Copy(FirstWord, 1, 2) = 'fe') and (FirstWord[3] in ['8', '9', 'a', 'b']) then
    Exit(True);
  // Unique local fc00::/7
  if (Length(FirstWord) >= 2) and ((Copy(FirstWord, 1, 2) = 'fc') or (Copy(FirstWord, 1, 2) = 'fd')) then
    Exit(True);
  // Multicast ff00::/8
  if (Length(FirstWord) >= 2) and (Copy(FirstWord, 1, 2) = 'ff') then
    Exit(True);
end;

// Validates http or https URL and extracts the host into AHost
function IsSafeHttpUrl(const AUrl: string; out AHost: string): boolean;
var
  U: string;
  P: integer;
begin
  Result := False;
  AHost := '';
  U := Trim(AUrl);
  if Copy(LowerCase(U), 1, 7) = 'http://' then
    U := Copy(U, 8, MaxInt)
  else if Copy(LowerCase(U), 1, 8) = 'https://' then
    U := Copy(U, 9, MaxInt)
  else
    Exit;
  // IPv6 literal in brackets: [::1], [2001:db8::1]:8080
  if (Length(U) > 0) and (U[1] = '[') then
  begin
    P := Pos(']', U);
    if P = 0 then
      Exit;
    AHost := LowerCase(Copy(U, 2, P - 2));
    Result := AHost <> '';
    Exit;
  end;
  // IPv4 or hostname, stop at port, path or query
  P := 1;
  while (P <= Length(U)) and not (U[P] in ['/', '?', '#', ':']) do
    Inc(P);
  AHost := LowerCase(Copy(U, 1, P - 1));
  Result := AHost <> '';
end;

// Returns True when the file contains binary data or cannot be inspected
function IsBinaryFile(const AFileName: string): boolean;
var
  Stream: TFileStream;
  Buffer: array of byte = nil;
  ReadCount, I: integer;
begin
  Result := False;
  try
    Stream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Buffer, 4096);
      ReadCount := Stream.Read(Buffer[0], Length(Buffer));
      for I := 0 to ReadCount - 1 do
        if Buffer[I] = 0 then
          Exit(True);
    finally
      Stream.Free;
    end;
  except
    Result := True;
  end;
end;

// Decodes &#NNN; and &#xHH; entities to UTF-8 bytes
function DecodeNumericEntities(const AText: string): string;
var
  I, EndPos, Code: integer;
  Hex: boolean;
  NumStr: string;
begin
  Result := '';
  I := 1;
  while I <= Length(AText) do
  begin
    if (AText[I] = '&') and (I < Length(AText)) and (AText[I + 1] = '#') then
    begin
      EndPos := PosFrom(';', AText, I + 2);
      if (EndPos > 0) and (EndPos - I <= 10) then
      begin
        NumStr := Copy(AText, I + 2, EndPos - I - 2);
        Hex := False;
        if (Length(NumStr) > 0) and ((NumStr[1] = 'x') or (NumStr[1] = 'X')) then
        begin
          Hex := True;
          Delete(NumStr, 1, 1);
        end;
        if Hex then
          Code := StrToIntDef('$' + NumStr, -1)
        else
          Code := StrToIntDef(NumStr, -1);
        if (Code > 0) and (Code < $110000) then
        begin
          if Code < $80 then
            Result := Result + Chr(Code)
          else if Code < $800 then
            Result := Result + Chr($C0 or (Code shr 6)) + Chr($80 or (Code and $3F))
          else if Code < $10000 then
            Result := Result + Chr($E0 or (Code shr 12)) + Chr($80 or ((Code shr 6) and $3F)) + Chr($80 or (Code and $3F))
          else
            Result := Result + Chr($F0 or (Code shr 18)) + Chr($80 or ((Code shr 12) and $3F)) +
              Chr($80 or ((Code shr 6) and $3F)) + Chr($80 or (Code and $3F));
          I := EndPos + 1;
          Continue;
        end;
      end;
    end;
    Result := Result + AText[I];
    Inc(I);
  end;
end;

// Strips HTML tags, script and style blocks, decodes common entities
function StripHtmlTags(const AHtml: string): string;
var
  I: integer;
  LowerHtml: string;
  InSkip: boolean;

// Skips the current element until its closing tag
  function SkipUntilClosing(const AOpenTag, ACloseTag: string): boolean;
  var
    ClosePos, EndPos: integer;
  begin
    Result := False;
    if Copy(LowerHtml, I, Length(AOpenTag)) <> AOpenTag then
      Exit;
    ClosePos := PosFrom(ACloseTag, LowerHtml, I);
    if ClosePos = 0 then
      Exit;
    EndPos := PosFrom('>', AHtml, ClosePos);
    if EndPos = 0 then
      EndPos := Length(AHtml);
    I := EndPos + 1;
    Result := True;
  end;

  // Ensures Result ends with a newline before appending more text
  procedure EnsureNewline;
  begin
    if (Result <> '') and (Result[Length(Result)] <> #10) then
      Result := Result + #10;
  end;

var
  TagEnd: integer;
  IsBrTag, IsBlockTag: boolean;
begin
  Result := '';
  LowerHtml := LowerCase(AHtml);
  I := 1;
  InSkip := False;
  while I <= Length(AHtml) do
  begin
    if AHtml[I] = '<' then
    begin
      InSkip := SkipUntilClosing('<script', '</script');
      if InSkip then
        Continue;
      InSkip := SkipUntilClosing('<style', '</style');
      if InSkip then
        Continue;
      // Classify block-level tags that should become newlines
      TagEnd := PosFrom('>', AHtml, I);
      IsBrTag := (Copy(LowerHtml, I, 3) = '<br') and (TagEnd > 0);
      IsBlockTag := (Copy(LowerHtml, I, 2) = '<p') or (Copy(LowerHtml, I, 3) = '</p') or (Copy(LowerHtml, I, 4) = '<div') or
        (Copy(LowerHtml, I, 5) = '</div') or (Copy(LowerHtml, I, 3) = '<li') or (Copy(LowerHtml, I, 4) = '</li') or
        (Copy(LowerHtml, I, 2) = '<h1') or (Copy(LowerHtml, I, 3) = '</h1') or (Copy(LowerHtml, I, 2) = '<h2') or
        (Copy(LowerHtml, I, 3) = '</h2') or (Copy(LowerHtml, I, 2) = '<h3') or (Copy(LowerHtml, I, 3) = '</h3') or
        (Copy(LowerHtml, I, 4) = '<ul>') or (Copy(LowerHtml, I, 5) = '</ul>') or (Copy(LowerHtml, I, 4) = '<ol>') or
        (Copy(LowerHtml, I, 5) = '</ol>');
      if IsBrTag then
        EnsureNewline
      else if IsBlockTag then
      begin
        EnsureNewline;
        // Opening tags like <p class=...> are safe to skip
        if TagEnd > 0 then
        begin
          I := TagEnd + 1;
          Continue;
        end;
      end;
      if TagEnd > 0 then
      begin
        I := TagEnd + 1;
        Continue;
      end;
    end;
    Result := Result + AHtml[I];
    Inc(I);
  end;
  // Normalize line endings, keep newlines
  Result := StringReplace(Result, #13#10, #10, [rfReplaceAll]);
  Result := StringReplace(Result, #13, #10, [rfReplaceAll]);
  // Collapse runs of spaces and tabs only, newlines stay intact
  while Pos('  ', Result) > 0 do
    Result := StringReplace(Result, '  ', ' ', [rfReplaceAll]);
  while Pos(#9, Result) > 0 do
    Result := StringReplace(Result, #9, ' ', [rfReplaceAll]);
  // Collapse repeated blank lines
  while Pos(#10#10#10, Result) > 0 do
    Result := StringReplace(Result, #10#10#10, #10#10, [rfReplaceAll]);
  // Decode numeric entities before named ones
  Result := DecodeNumericEntities(Result);
  // Decode common named entities
  Result := StringReplace(Result, '&amp;', '&', [rfReplaceAll]);
  Result := StringReplace(Result, '&lt;', '<', [rfReplaceAll]);
  Result := StringReplace(Result, '&gt;', '>', [rfReplaceAll]);
  Result := StringReplace(Result, '&quot;', '"', [rfReplaceAll]);
  Result := StringReplace(Result, '&#39;', '''', [rfReplaceAll]);
  Result := StringReplace(Result, '&apos;', '''', [rfReplaceAll]);
  Result := StringReplace(Result, '&nbsp;', ' ', [rfReplaceAll]);
end;

// Converts git-style globs like **/*.md and [Aa] classes to Windows patterns
function NormalizeGlobPattern(const APattern: string): string;
var
  I, BracketEnd: integer;
begin
  Result := APattern;
  // Strip git-style **/ prefix, FindAllFiles is already recursive
  if (Copy(Result, 1, 3) = '**/') or (Copy(Result, 1, 3) = '**\') then
    Delete(Result, 1, 3)
  else if Copy(Result, 1, 2) = '**' then
    Result := '*' + Copy(Result, 3, MaxInt);
  // Replace [Xy] classes with first character, Windows FS is case-insensitive
  I := 1;
  while I <= Length(Result) do
  begin
    if Result[I] = '[' then
    begin
      BracketEnd := Pos(']', Result, I);
      if BracketEnd > I + 1 then
      begin
        Result := Copy(Result, 1, I - 1) + Result[I + 1] + Copy(Result, BracketEnd + 1, MaxInt);
        Inc(I);
        Continue;
      end;
    end;
    Inc(I);
  end;
  // Normalize slashes to platform delimiters
  Result := StringReplace(Result, '/', PathDelim, [rfReplaceAll]);
end;

// Expands {a,b,c} alternatives into separate patterns, supports nesting
function ExpandBracePatterns(const APattern: string): TStringList;
var
  P1, P2, I, Start: integer;
  Prefix, Suffix, Body, Item: string;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := False;
  Result.Duplicates := dupIgnore;
  P1 := Pos('{', APattern);
  if P1 = 0 then
  begin
    Result.Add(APattern);
    Exit;
  end;
  P2 := Pos('}', APattern, P1 + 1);
  if P2 = 0 then
  begin
    Result.Add(APattern);
    Exit;
  end;
  Prefix := Copy(APattern, 1, P1 - 1);
  Suffix := Copy(APattern, P2 + 1, MaxInt);
  Body := Copy(APattern, P1 + 1, P2 - P1 - 1);
  Start := 1;
  for I := 1 to Length(Body) + 1 do
  begin
    if (I > Length(Body)) or (Body[I] = ',') then
    begin
      Item := Copy(Body, Start, I - Start);
      Start := I + 1;
      Result.AddStrings(ExpandBracePatterns(Prefix + Item + Suffix));
    end;
  end;
end;

// Loads simple .gitignore rules from ARootPath, skips comments and negations
function LoadGitignorePatterns(const ARootPath: string): TStringList;
var
  GitignorePath: string;
  Lines: TStringList;
  I: integer;
  S: string;
begin
  Result := TStringList.Create;
  GitignorePath := IncludeTrailingPathDelimiter(ARootPath) + '.gitignore';
  if not FileExists(GitignorePath) then
    Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(GitignorePath);
    except
      Exit;
    end;
    for I := 0 to Lines.Count - 1 do
    begin
      S := Trim(Lines[I]);
      if (S = '') or (S[1] = '#') or (S[1] = '!') then
        Continue;
      Result.Add(LowerCase(StringReplace(S, '\', '/', [rfReplaceAll])));
    end;
  finally
    Lines.Free;
  end;
end;

// Returns True when the relative path matches any .gitignore rule
function IsIgnoredByGitignore(const ARelPath: string; APatterns: TStringList): boolean;
var
  I: integer;
  P, LowPath, LowName: string;
  SlashPos: integer;
begin
  Result := False;
  if (APatterns = nil) or (APatterns.Count = 0) then
    Exit;
  LowPath := '/' + LowerCase(StringReplace(ARelPath, '\', '/', [rfReplaceAll]));
  SlashPos := LastDelimiter('/', LowPath);
  if SlashPos > 0 then
    LowName := Copy(LowPath, SlashPos + 1, MaxInt)
  else
    LowName := LowPath;
  for I := 0 to APatterns.Count - 1 do
  begin
    P := APatterns[I];
    // Directory pattern with trailing slash matches any /dir/ segment
    if (Length(P) > 0) and (P[Length(P)] = '/') then
    begin
      Delete(P, Length(P), 1);
      if Pos('/' + P + '/', LowPath) > 0 then
        Exit(True);
    end
    // Root-anchored pattern matches from the root only
    else if (Length(P) > 0) and (P[1] = '/') then
    begin
      Delete(P, 1, 1);
      if Copy(LowPath, 2, Length(P) + 1) = P + '/' then
        Exit(True)
      else if LowPath = '/' + P then
        Exit(True);
    end
    // Pattern with a slash matches as a path suffix
    else if Pos('/', P) > 0 then
    begin
      if Pos('/' + P + '/', LowPath) > 0 then
        Exit(True);
    end
    // Simple name or glob matches the basename only
    else if MatchesMask(LowName, P) then
      Exit(True);
  end;
end;

// Finds a safe cut point for history compaction, -1 when no valid cut exists
function FindCompactionCutPoint(AMessages: TJSONArray; AKeepLast: integer): integer;
var
  I: integer;
  MsgObj: TJSONObject;
  Role: string;
begin
  Result := -1;
  if (AMessages = nil) or (AMessages.Count <= AKeepLast + 2) then
    Exit;
  I := AMessages.Count - AKeepLast;
  while I > 1 do
  begin
    if AMessages.Items[I].JSONType <> jtObject then
    begin
      Dec(I);
      Continue;
    end;
    MsgObj := TJSONObject(AMessages.Items[I]);
    Role := MsgObj.Get('role', '');
    // Safe cut: right before a user message or a plain assistant (no pending tool calls)
    if (Role = 'user') or ((Role = 'assistant') and (MsgObj.Find('tool_calls') = nil)) then
    begin
      Result := I;
      Exit;
    end;
    Dec(I);
  end;
end;

// Reads an integer argument, accepting number or string forms like "102400.0"
function GetIntArg(AArgs: TJSONObject; const AName: string; ADefault: int64): int64;
var
  Data: TJSONData;
  S: string;
  F: double;
  FS: TFormatSettings;
begin
  Result := ADefault;
  if AArgs = nil then
    Exit;
  Data := AArgs.Find(AName);
  if Data = nil then
    Exit;
  case Data.JSONType of
    jtNumber:
      Result := Data.AsInt64;
    jtBoolean:
      if Data.AsBoolean then
        Result := 1
      else
        Result := 0;
    jtString:
    begin
      S := Trim(Data.AsString);
      if TryStrToInt64(S, Result) then
        Exit;
      // Some models send "102400.0", accept and round with a fixed
      // dot separator so the value parses on any locale
      FS := DefaultFormatSettings;
      FS.DecimalSeparator := '.';
      FS.ThousandSeparator := #0;
      if TryStrToFloat(S, F, FS) then
        Result := Round(F)
      else
        Result := ADefault;
    end;
    else
      ;
  end;
end;

// Reads a boolean argument, accepting bool, number or string forms
function GetBoolArg(AArgs: TJSONObject; const AName: string; ADefault: boolean): boolean;
var
  Data: TJSONData;
  S: string;
begin
  Result := ADefault;
  if AArgs = nil then
    Exit;
  Data := AArgs.Find(AName);
  if Data = nil then
    Exit;
  case Data.JSONType of
    jtBoolean:
      Result := Data.AsBoolean;
    jtNumber:
      Result := Data.AsInt64 <> 0;
    jtString:
    begin
      S := LowerCase(Trim(Data.AsString));
      if (S = 'true') or (S = '1') or (S = 'yes') or (S = 'on') then
        Result := True
      else if (S = 'false') or (S = '0') or (S = 'no') or (S = 'off') then
        Result := False;
    end;
    else
      ;
  end;
end;

// Returns True for build artifacts and VCS metadata that clutter file listings
function IsJunkFileForFind(const ARelPath: string): boolean;
var
  Low: string;
begin
  Low := '/' + LowerCase(StringReplace(ARelPath, '\', '/', [rfReplaceAll])) + '/';
  Result := (Pos('/.git/', Low) > 0) or (Pos('/.svn/', Low) > 0) or (Pos('/.hg/', Low) > 0);
end;

// Returns True when the pattern contains regex syntax that almost never
// appears in a literal search term (anchors, word classes, alternation)
function PatternLooksLikeRegex(const APattern: string): boolean;
var
  I: integer;
begin
  Result := False;
  if APattern = '' then
    Exit;
  // Line anchors at boundaries
  if (APattern[1] = '^') or (APattern[Length(APattern)] = '$') then
    Exit(True);
  // Escaped character classes or escaped metacharacters
  for I := 1 to Length(APattern) - 1 do
  begin
    if APattern[I] = '\' then
    begin
      if APattern[I + 1] in ['w', 'W', 'd', 'D', 's', 'S', 'b', 'B', '.', '(', ')', '[', ']', '{', '}',
        '+', '*', '?', '^', '$', '|', '\'] then
        Exit(True);
    end;
  end;
  // Alternation with no surrounding spaces
  for I := 2 to Length(APattern) - 1 do
    if (APattern[I] = '|') and (APattern[I - 1] <> ' ') and (APattern[I + 1] <> ' ') then
      Exit(True);
end;

// Returns the Levenshtein edit distance between two strings
function LevenshteinDistance(const S1, S2: string): integer;
var
  I, J, Diag, Up, Left, Best: integer;
  Prev, Cur: array of integer;
begin
  if Length(S1) = 0 then
    Exit(Length(S2));
  if Length(S2) = 0 then
    Exit(Length(S1));
  Prev := nil;
  Cur := nil;
  SetLength(Prev, Length(S2) + 1);
  SetLength(Cur, Length(S2) + 1);
  for J := 0 to Length(S2) do
    Prev[J] := J;
  for I := 1 to Length(S1) do
  begin
    Cur[0] := I;
    for J := 1 to Length(S2) do
    begin
      if S1[I] = S2[J] then
        Cur[J] := Prev[J - 1]
      else
      begin
        Diag := Prev[J - 1];
        Up := Prev[J];
        Left := Cur[J - 1];
        Best := Diag;
        if Up < Best then
          Best := Up;
        if Left < Best then
          Best := Left;
        Cur[J] := Best + 1;
      end;
    end;
    // Swap rows without reallocating, Prev becomes the finished Cur
    for J := 0 to Length(S2) do
    begin
      Left := Prev[J];
      Prev[J] := Cur[J];
      Cur[J] := Left;
    end;
  end;
  Result := Prev[Length(S2)];
end;

// Returns True for well-known secret files that should not be exposed to the LLM
function IsSensitiveFile(const AFullPath: string): boolean;
var
  Low, Name, Ext: string;
begin
  Result := False;
  Low := '/' + LowerCase(StringReplace(AFullPath, '\', '/', [rfReplaceAll])) + '/';
  // Credential directories anywhere in the path
  if (Pos('/.ssh/', Low) > 0) or (Pos('/.aws/', Low) > 0) or (Pos('/.gnupg/', Low) > 0) then
    Exit(True);
  Name := LowerCase(ExtractFileName(AFullPath));
  Ext := LowerCase(ExtractFileExt(AFullPath));
  // Private key and certificate containers
  if (Ext = '.key') or (Ext = '.pfx') or (Ext = '.p12') or (Ext = '.pem') then
    Exit(True);
  // Environment files
  if (Name = '.env') or (Copy(Name, 1, 5) = '.env.') then
    Exit(True);
  // SSH private keys without extension
  if (Name = 'id_rsa') or (Name = 'id_ed25519') or (Name = 'id_ecdsa') or (Name = 'id_dsa') then
    Exit(True);
end;

{ TAgentWebOptions }

constructor TAgentWebOptions.Create;
begin
  inherited Create;
  FSearchUrl := 'https://html.duckduckgo.com/html/?q={query}';
  FUserAgent := 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ' + 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  FRequestTimeout := 15000;
  FMaxResponseBytes := 524288;
  FStripHtml := True;
  FBlockLocalhost := True;
  FBlockPrivateIPs := True;
  FAllowedHosts := TStringList.Create;
  FAllowedHosts.CaseSensitive := False;
end;

destructor TAgentWebOptions.Destroy;
begin
  FAllowedHosts.Free;
  inherited Destroy;
end;

procedure TAgentWebOptions.SetAllowedHosts(const AValue: TStringList);
begin
  FAllowedHosts.Assign(AValue);
end;

procedure TAgentWebOptions.Assign(Source: TPersistent);
var
  Src: TAgentWebOptions;
begin
  if Source is TAgentWebOptions then
  begin
    Src := TAgentWebOptions(Source);
    FSearchUrl := Src.FSearchUrl;
    FUserAgent := Src.FUserAgent;
    FRequestTimeout := Src.FRequestTimeout;
    FMaxResponseBytes := Src.FMaxResponseBytes;
    FStripHtml := Src.FStripHtml;
    FBlockLocalhost := Src.FBlockLocalhost;
    FBlockPrivateIPs := Src.FBlockPrivateIPs;
    FAllowedHosts.Assign(Src.FAllowedHosts);
  end
  else
    inherited Assign(Source);
end;

type
  // Holder for async event delivery through TThread.Queue
  TAgentCallBase = class
  public
    Agent: TCustomOllamaAgent;
    procedure Invoke; virtual; abstract;
  end;

  TRouteCall = class(TAgentCallBase)
  public
    Op: TAgentOperation;
    Payload: string;
    Allow: boolean;
    procedure Invoke; override;
  end;

  TChunkCall = class(TAgentCallBase)
  public
    Text: string;
    procedure Invoke; override;
  end;

  TThinkingCall = class(TAgentCallBase)
  public
    Text: string;
    procedure Invoke; override;
  end;

  TToolCallCall = class(TAgentCallBase)
  public
    Name, Args: string;
    procedure Invoke; override;
  end;

  TToolResultCall = class(TAgentCallBase)
  public
    Name, Result: string;
    procedure Invoke; override;
  end;

  TFinishCall = class(TAgentCallBase)
  public
    Reason: TAgentFinishReason;
    Answer, ErrorMsg: string;
    procedure Invoke; override;
  end;

  TExecCommandCall = class(TAgentCallBase)
  public
    Command: string;
    Allow: boolean;
    Result: string;
    procedure Invoke; override;
  end;

  TAskUserCall = class(TAgentCallBase)
  public
    Question: string;
    Answer: string;
    Allow: boolean;
    procedure Invoke; override;
  end;

  TLogCall = class(TAgentCallBase)
  public
    Text: string;
    procedure Invoke; override;
  end;

  // Worker thread that runs one tool call in parallel with others
  TToolExecThread = class(TThread)
  private
    FAgent: TCustomOllamaAgent;
    FToolName: string;
    FToolArgs: string;
    FResult: string;
  protected
    procedure Execute; override;
  public
    constructor Create(AAgent: TCustomOllamaAgent; const AName, AArgs: string);
    property ToolResult: string read FResult;
  end;

constructor TToolExecThread.Create(AAgent: TCustomOllamaAgent; const AName, AArgs: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FAgent := AAgent;
  FToolName := AName;
  FToolArgs := AArgs;
  FResult := '';
  Start;
end;

procedure TToolExecThread.Execute;
begin
  try
    FResult := FAgent.DispatchTool(FToolName, FToolArgs);
  except
    on E: Exception do
      FResult := '{"error": ' + TJSONString.Create(E.Message).AsJSON + '}';
  end;
end;

procedure TRouteCall.Invoke;
begin
  if Assigned(Agent.FOnRoute) then
  try
    Agent.FOnRoute(Agent, Op, Payload, Allow);
  except
    Allow := False;
  end;
end;

procedure TChunkCall.Invoke;
begin
  try
    if Assigned(Agent.FOnChunk) then
    try
      Agent.FOnChunk(Agent, Text);
    except
      ; // Swallow host handler errors, must not kill the main loop
    end;
  finally
    Free;
  end;
end;

procedure TThinkingCall.Invoke;
begin
  try
    if Assigned(Agent.FOnThinking) then
    try
      Agent.FOnThinking(Agent, Text);
    except
      ; // Swallow host handler errors
    end;
  finally
    Free;
  end;
end;

procedure TToolCallCall.Invoke;
begin
  try
    if Assigned(Agent.FOnToolCall) then
    try
      Agent.FOnToolCall(Agent, Name, Args);
    except
      ; // Swallow host handler errors
    end;
  finally
    Free;
  end;
end;

procedure TToolResultCall.Invoke;
begin
  try
    if Assigned(Agent.FOnToolResult) then
    try
      Agent.FOnToolResult(Agent, Name, Result);
    except
      ; // Swallow host handler errors
    end;
  finally
    Free;
  end;
end;

procedure TFinishCall.Invoke;
begin
  try
    if Assigned(Agent.FOnFinish) then
      Agent.FOnFinish(Agent, Reason, Answer, ErrorMsg);
    // Log inside Invoke so it runs after the finish handler and before Done is set
    if Agent.FLog then
    begin
      WriteLn(ErrOutput, Format('[agent] Finish reason=%s answer_len=%d error="%s"',
        [AgentFinishReasonName(Reason), Length(Answer), ErrorMsg]));
      Flush(ErrOutput);
    end;
  finally
    Free;
  end;
end;

procedure TExecCommandCall.Invoke;
begin
  Allow := True;
  Result := '';
  if Assigned(Agent.FOnExecCommand) then
  try
    Agent.FOnExecCommand(Agent, Command, Result, Allow);
  except
    ; // User handler raised, treat as no-op
  end;
end;

procedure TAskUserCall.Invoke;
begin
  Allow := True;
  Answer := '';
  if Assigned(Agent.FOnAskUser) then
  try
    Agent.FOnAskUser(Agent, Question, Answer, Allow);
  except
    Allow := False;
  end;
end;

procedure TLogCall.Invoke;
begin
  try
    if Assigned(Agent) and Assigned(Agent.FOnLog) then
    begin
      try
        Agent.FOnLog(Agent, Text);
      except
        ; // Host handler raised, ignore
      end;
    end
    else
    try
      WriteLn(ErrOutput, Text);
      Flush(ErrOutput);
    except
      ; // Console may be detached, ignore
    end;
  finally
    Free;
  end;
end;

type
  // Worker thread executing one agent run
  TOllamaAgentThread = class(TThread)
  private
    FAgent: TCustomOllamaAgent;
    FUserText: string;
    FCurrentContent: string;
    procedure HandleStreamChunk(const AContent: string; var ACancel: boolean);
    procedure HandleFullContent(const AContent: string; var ACancel: boolean);
    procedure HandleThinkingChunk(const AText: string; var ACancel: boolean);
    procedure QueueRoute(AOp: TAgentOperation; const APayload: string; out AAllow: boolean);
    procedure QueueChunk(const AText: string);
    procedure QueueThinking(const AText: string);
    procedure QueueToolCall(const AName, AArgs: string);
    procedure QueueToolResult(const AName, AResult: string);
    procedure QueueFinish(AReason: TAgentFinishReason; const AAnswer, AErrorMsg: string);
  protected
    procedure Execute; override;
  public
    constructor Create(AAgent: TCustomOllamaAgent; const AUserText: string);
  end;

  { TOllamaAgentThread }

constructor TOllamaAgentThread.Create(AAgent: TCustomOllamaAgent; const AUserText: string);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FAgent := AAgent;
  FUserText := AUserText;
  FCurrentContent := '';
  Start;
end;

procedure TOllamaAgentThread.HandleStreamChunk(const AContent: string; var ACancel: boolean);
begin
  if FAgent.FCancelled then
  begin
    ACancel := True;
    Exit;
  end;
  FCurrentContent := FCurrentContent + AContent;
  if FAgent.FStreaming then
    QueueChunk(AContent);
end;

procedure TOllamaAgentThread.HandleFullContent(const AContent: string; var ACancel: boolean);
begin
  if FAgent.FCancelled then
  begin
    ACancel := True;
    Exit;
  end;
  FCurrentContent := FCurrentContent + AContent;
  // Non-streaming call, emit full content as one chunk
  QueueChunk(AContent);
end;

procedure TOllamaAgentThread.HandleThinkingChunk(const AText: string; var ACancel: boolean);
begin
  if FAgent.FCancelled then
  begin
    ACancel := True;
    Exit;
  end;
  QueueThinking(AText);
end;

procedure TOllamaAgentThread.QueueRoute(AOp: TAgentOperation; const APayload: string; out AAllow: boolean);
var
  Call: TRouteCall;
begin
  AAllow := True;
  FAgent.LogLine(Format('Route op=%s payload="%s"', [AgentOpName(AOp), Copy(APayload, 1, 200)]));
  if not Assigned(FAgent.FOnRoute) then
    Exit;
  Call := TRouteCall.Create;
  try
    Call.Agent := FAgent;
    Call.Op := AOp;
    Call.Payload := APayload;
    Call.Allow := True;
    TThread.Synchronize(nil, @Call.Invoke);
    AAllow := Call.Allow;
  finally
    Call.Free;
  end;
end;

procedure TOllamaAgentThread.QueueChunk(const AText: string);
var
  Call: TChunkCall;
begin
  // Chunks are visible as streamed text, no separate log line needed
  if not Assigned(FAgent.FOnChunk) then
    Exit;
  Call := TChunkCall.Create;
  Call.Agent := FAgent;
  Call.Text := AText;
  TThread.Queue(nil, @Call.Invoke);
end;

procedure TOllamaAgentThread.QueueThinking(const AText: string);
var
  Call: TThinkingCall;
begin
  // No per-chunk log here, it would close the thinking block on every chunk
  if not Assigned(FAgent.FOnThinking) then
    Exit;
  Call := TThinkingCall.Create;
  Call.Agent := FAgent;
  Call.Text := AText;
  TThread.Queue(nil, @Call.Invoke);
end;

procedure TOllamaAgentThread.QueueToolCall(const AName, AArgs: string);
var
  Call: TToolCallCall;
begin
  FAgent.LogLine(Format('ToolCall name="%s" args="%s"', [AName, Copy(AArgs, 1, 200)]));
  if not Assigned(FAgent.FOnToolCall) then
    Exit;
  Call := TToolCallCall.Create;
  Call.Agent := FAgent;
  Call.Name := AName;
  Call.Args := AArgs;
  TThread.Queue(nil, @Call.Invoke);
end;

procedure TOllamaAgentThread.QueueToolResult(const AName, AResult: string);
var
  Call: TToolResultCall;
begin
  FAgent.LogLine(Format('ToolResult name="%s" result_len=%d', [AName, Length(AResult)]));
  // Emit result preview through the same log channel, independent of Log
  FAgent.EmitToolResult(AName, AResult);
  if not Assigned(FAgent.FOnToolResult) then
    Exit;
  Call := TToolResultCall.Create;
  Call.Agent := FAgent;
  Call.Name := AName;
  Call.Result := AResult;
  TThread.Queue(nil, @Call.Invoke);
end;

procedure TOllamaAgentThread.QueueFinish(AReason: TAgentFinishReason; const AAnswer, AErrorMsg: string);
var
  Call: TFinishCall;
begin
  // Synchronize so finish handler and log run before Done is set
  Call := TFinishCall.Create;
  Call.Agent := FAgent;
  Call.Reason := AReason;
  Call.Answer := AAnswer;
  Call.ErrorMsg := AErrorMsg;
  TThread.Synchronize(nil, @Call.Invoke);
end;

procedure TOllamaAgentThread.Execute;
const
  // Tool results older than the most recent N are truncated to save context
  KEEP_RECENT_TOOL_RESULTS = 3;
  // Maximum size of a truncated tool result in bytes
  TRUNCATE_TOOL_BYTES = 1000;
  // Retry limit for the chat call on transport timeout
  CHAT_MAX_ATTEMPTS = 3;
  // Maximum retries after an empty model response
  MAX_EMPTY_RESPONSE_RETRIES = 2;
  // Compaction triggers when context usage reaches this percent
  COMPACT_THRESHOLD_PCT = 75;
  // Minimum number of messages before compaction is attempted
  COMPACT_MIN_MESSAGES = 10;
  // Always keep at least this many messages from the end after compaction
  KEEP_RECENT_MESSAGES = 5;
  // Cap on the total bytes sent to the summarizer, prevents overflow
  MAX_SUMMARIZE_INPUT_CHARS = 80000;
  // Per-message cap when building the summarizer input
  MAX_SUMMARIZE_MSG_CHARS = 5000;
var
  Step, I, SavedTimeout, EffectiveMaxSteps: integer;
  EmptyResponseRetries: integer;
  MessagesArr: TJSONArray;
  MessagesJson, ToolsJson, FinalJson, ErrMsg: string;
  Kind: TOllamaErrorKind;
  Allow: boolean;
  Reason: TAgentFinishReason;
  Data, MessageData, ToolCallsData, FuncData, ArgsData: TJSONData;
  ToolCallsArr: TJSONArray;
  ToolCallObj, FuncObj, MsgObj: TJSONObject;
  FinalContent: string;
  Attempt, TruncIdx, TruncSeen, TruncTotalTool: integer;
  TruncContent: string;
  ResolvedCtx: int64;
  SystemPromptText: string;
  CutPoint: integer;
  OldMsgsStr, MsgStr, Summary: string;
  NewArr: TJSONArray;
  SummObj: TJSONObject;
  SendTools: boolean;
  ToolCount, ToolIdx, CollectIdx: integer;
  ToolNames, ToolArgArr, ToolResultArr: array of string;
  ToolAllowArr: array of boolean;
  AllParallelSafe: boolean;
  Threads: TList;
  SupportsTools: boolean;
begin
  Reason := afrError;
  ErrMsg := '';
  FinalContent := '';
  EmptyResponseRetries := 0;
  // Initialize managed array locals to silence compiler hints
  ToolNames := nil;
  ToolArgArr := nil;
  ToolAllowArr := nil;
  ToolResultArr := nil;
  MessagesArr := TJSONArray.Create;
  FAgent.LogLine(Format('Run start model="%s" text_len=%d', [FAgent.ModelName, Length(FUserText)]));
  try
    try
      if FAgent.OllamaManager = nil then
      begin
        Reason := afrModelNotSet;
        ErrMsg := 'OllamaManager is not assigned';
        FAgent.LogLine('Abort: OllamaManager nil');
        Exit;
      end;
      if Trim(FAgent.ModelName) = '' then
      begin
        Reason := afrModelNotSet;
        ErrMsg := 'ModelName is empty';
        FAgent.LogLine('Abort: ModelName empty');
        Exit;
      end;

      // Always verify the model is on the server, regardless of tools setting
      SupportsTools := FAgent.ModelSupportsTools(ErrMsg);
      if not SupportsTools then
      begin
        // Hard fail when the model itself is missing
        if Pos('is not available on the server', ErrMsg) > 0 then
        begin
          Reason := afrModelNotSet;
          FAgent.LogLine('Abort: ' + ErrMsg);
          Exit;
        end;
        // Model exists but lacks tool support, degrade to chat-only
        if FAgent.FFeatures <> [] then
          FAgent.LogLine('Warning: ' + ErrMsg + ', continuing without tools');
      end;
      SendTools := SupportsTools and (FAgent.FFeatures <> []);

      // Always send the system message, BuildSystemPrompt adds platform,
      // workspace and enabled tools even when the user prompt is empty
      SystemPromptText := FAgent.BuildSystemPrompt;
      FAgent.LogLine(Format('System prompt len=%d preview="%s"', [Length(SystemPromptText), Copy(SystemPromptText, 1, 400)]));
      MsgObj := TJSONObject.Create;
      MsgObj.Add('role', 'system');
      MsgObj.Add('content', SystemPromptText);
      MessagesArr.Add(MsgObj);

      if FAgent.KeepHistory and (FAgent.FHistory <> '') then
      begin
        Data := nil;
        try
          try
            Data := GetJSON(FAgent.FHistory);
            if (Data <> nil) and (Data.JSONType = jtArray) then
              for I := 0 to TJSONArray(Data).Count - 1 do
                MessagesArr.Add(TJSONArray(Data).Items[I].Clone);
          except
            ; // Ignore invalid history
          end;
        finally
          Data.Free;
        end;
      end;

      MsgObj := TJSONObject.Create;
      MsgObj.Add('role', 'user');
      // Prepend host-supplied context such as recent shell commands
      if FAgent.FContextPrelude <> '' then
        MsgObj.Add('content', FAgent.FContextPrelude + #10#10 + FUserText)
      else
        MsgObj.Add('content', FUserText);
      MessagesArr.Add(MsgObj);

      if SendTools then
        ToolsJson := FAgent.BuildToolsSchemaJson
      else
        ToolsJson := '';
      FAgent.LogLine(Format('Streaming=%s tools: fileTools=%s exec=%s git=%s interactive=%s finish=%s web=%s',
        [BoolToStr(FAgent.FStreaming, 'on', 'off'), BoolToStr(afFileTools in FAgent.FFeatures, 'on', 'off'),
        BoolToStr(afExecCommand in FAgent.FFeatures, 'on', 'off'), BoolToStr(afGit in FAgent.FFeatures, 'on', 'off'),
        BoolToStr(afInteractive in FAgent.FFeatures, 'on', 'off'), BoolToStr(afFinish in FAgent.FFeatures, 'on', 'off'),
        BoolToStr(afWebTools in FAgent.FFeatures, 'on', 'off')]));
      FAgent.LogLine(Format('Tools schema len=%d names=[%s]', [Length(ToolsJson), FAgent.BuildToolsNames]));

      // MaxSteps = 0 means unlimited
      if FAgent.MaxSteps > 0 then
        EffectiveMaxSteps := FAgent.MaxSteps
      else
        EffectiveMaxSteps := MaxInt;

      for Step := 1 to EffectiveMaxSteps do
      begin
        if FAgent.FCancelled then
        begin
          Reason := afrCancelled;
          Exit;
        end;

        QueueRoute(aoChat, 'step ' + IntToStr(Step), Allow);
        if not Allow then
        begin
          Reason := afrError;
          ErrMsg := 'Chat rejected by host';
          Exit;
        end;

        FCurrentContent := '';
        // Compact history when context is near full and there is room to cut
        if (FAgent.FContextTotal > 0) and (FAgent.FContextUsed > 0) and (FAgent.FContextUsed * 100 div
          FAgent.FContextTotal >= COMPACT_THRESHOLD_PCT) and (MessagesArr.Count > COMPACT_MIN_MESSAGES) then
        begin
          CutPoint := FindCompactionCutPoint(MessagesArr, KEEP_RECENT_MESSAGES);
          if CutPoint > 1 then
          begin
            FAgent.LogLine(Format('Compacting: context %d/%d, %d old messages', [FAgent.FContextUsed,
              FAgent.FContextTotal, CutPoint - 1]));
            // Build a bounded input for the summarizer
            OldMsgsStr := '';
            for I := 1 to CutPoint - 1 do
            begin
              if MessagesArr.Items[I].JSONType <> jtObject then
                Continue;
              MsgStr := MessagesArr.Items[I].AsJSON;
              if Length(MsgStr) > MAX_SUMMARIZE_MSG_CHARS then
                MsgStr := Copy(MsgStr, 1, MAX_SUMMARIZE_MSG_CHARS) + '...[truncated]';
              OldMsgsStr := OldMsgsStr + MsgStr + #10;
              if Length(OldMsgsStr) >= MAX_SUMMARIZE_INPUT_CHARS then
              begin
                OldMsgsStr := OldMsgsStr + '[... remaining messages omitted ...]';
                Break;
              end;
            end;
            Summary := FAgent.SummarizeMessages(OldMsgsStr);
            if Summary <> '' then
            begin
              NewArr := TJSONArray.Create;
              try
                // Preserve original system message
                NewArr.Add(MessagesArr.Items[0].Clone);
                // Insert summary as a second system message
                SummObj := TJSONObject.Create;
                SummObj.Add('role', 'system');
                SummObj.Add('content', '[Summary of earlier conversation]' + #10 + Summary);
                NewArr.Add(SummObj);
                // Keep messages from CutPoint onward
                for I := CutPoint to MessagesArr.Count - 1 do
                  NewArr.Add(MessagesArr.Items[I].Clone);
                MessagesArr.Free;
                MessagesArr := NewArr;
                NewArr := nil;
                FAgent.LogLine('Compaction done');
              finally
                NewArr.Free;
              end;
            end
            else
              FAgent.LogLine('Compaction skipped, empty summary');
          end
          else
            FAgent.LogLine('Compaction skipped, no safe cut point');
        end;

        // Keep only the most recent tool results intact, older ones are truncated
        TruncTotalTool := 0;
        for TruncIdx := 0 to MessagesArr.Count - 1 do
          if (MessagesArr.Items[TruncIdx].JSONType = jtObject) and
            (TJSONObject(MessagesArr.Items[TruncIdx]).Get('role', '') = 'tool') then
            Inc(TruncTotalTool);
        TruncSeen := 0;
        for TruncIdx := 0 to MessagesArr.Count - 1 do
        begin
          if MessagesArr.Items[TruncIdx].JSONType <> jtObject then
            Continue;
          MsgObj := TJSONObject(MessagesArr.Items[TruncIdx]);
          if MsgObj.Get('role', '') <> 'tool' then
            Continue;
          Inc(TruncSeen);
          if TruncSeen > TruncTotalTool - KEEP_RECENT_TOOL_RESULTS then
            Continue;
          TruncContent := MsgObj.Get('content', '');
          if Length(TruncContent) > TRUNCATE_TOOL_BYTES then
          begin
            TruncContent := Copy(TruncContent, 1, TRUNCATE_TOOL_BYTES) + '...[truncated, original ' +
              IntToStr(Length(TruncContent)) + ' bytes]';
            MsgObj.Strings['content'] := TruncContent;
          end;
        end;

        MessagesJson := MessagesArr.AsJSON;
        FAgent.LogLine(Format('Step %d messages=%d timeout=%d request_json_bytes=%d',
          [Step, MessagesArr.Count, FAgent.OllamaManager.RequestTimeout, Length(MessagesJson)]));

        // Log the last assistant tool call
        for I := MessagesArr.Count - 1 downto 0 do
        begin
          if MessagesArr.Items[I].JSONType <> jtObject then
            Continue;
          MsgObj := TJSONObject(MessagesArr.Items[I]);
          if (MsgObj.Get('role', '') = 'assistant') and (MsgObj.Find('tool_calls') <> nil) then
          begin
            FAgent.LogLine('Last assistant tool call: ' + MsgObj.AsJSON);
            Break;
          end;
        end;

        // Log metadata of the last tool result without duplicating its content
        for I := MessagesArr.Count - 1 downto 0 do
        begin
          if MessagesArr.Items[I].JSONType <> jtObject then
            Continue;
          MsgObj := TJSONObject(MessagesArr.Items[I]);
          if MsgObj.Get('role', '') = 'tool' then
          begin
            FAgent.LogLine(Format('Last tool result: content_len=%d', [Length(MsgObj.Get('content', ''))]));
            Break;
          end;
        end;

        // Temporarily override manager timeout when agent has its own
        SavedTimeout := FAgent.OllamaManager.RequestTimeout;
        if FAgent.FRequestTimeout > 0 then
          FAgent.OllamaManager.RequestTimeout := FAgent.FRequestTimeout;
        try
          // Retry transient errors and ask the model to regenerate malformed tool calls
          for Attempt := 1 to CHAT_MAX_ATTEMPTS do
          begin
            FCurrentContent := '';
            if FAgent.FStreaming then
              FinalJson := FAgent.OllamaManager.ChatStream(FAgent.ModelName, MessagesJson, ToolsJson,
                @HandleStreamChunk, @HandleThinkingChunk, Kind, ErrMsg)
            else
              FinalJson := FAgent.OllamaManager.ChatWithTools(FAgent.ModelName, MessagesJson, ToolsJson,
                @HandleFullContent, @HandleThinkingChunk, Kind, ErrMsg);

            if (Kind = oekNone) or FAgent.FCancelled or (Kind = oekCancelled) then
              Break;

            // Ollama rejects malformed tool calls before they reach the client
            if (Kind = oekHttpServer) and (FCurrentContent = '') and
              (Pos('error parsing tool call', LowerCase(ErrMsg)) > 0) and (Attempt < CHAT_MAX_ATTEMPTS) then
            begin
              FAgent.LogLine('Malformed tool call rejected by Ollama, asking model to retry');
              MsgObj := TJSONObject.Create;
              MsgObj.Add('role', 'system');
              MsgObj.Add('content',
                'Your previous response contained a malformed tool call and could not be processed. ' +
                'Retry the same operation. Every tool call argument must contain only a valid JSON object. ' +
                'Do not append explanations or any other text to the JSON arguments.');
              MessagesArr.Add(MsgObj);
              MessagesJson := MessagesArr.AsJSON;
              Continue;
            end;

            if not (Kind in [oekTimeout, oekConnection]) or (FCurrentContent <> '') or (Attempt = CHAT_MAX_ATTEMPTS) then
              Break;
            FAgent.LogLine(Format('Chat connection error, retrying (attempt %d of %d)', [Attempt + 1, CHAT_MAX_ATTEMPTS]));
            Sleep(500 * Attempt);
          end;
        finally
          FAgent.OllamaManager.RequestTimeout := SavedTimeout;
        end;

        if FAgent.FCancelled or (Kind = oekCancelled) then
        begin
          Reason := afrCancelled;
          FAgent.LogLine('Abort: cancelled during chat');
          Exit;
        end;

        if Kind <> oekNone then
        begin
          Reason := afrError;
          if ErrMsg = '' then
            ErrMsg := 'LLM error';
          // HTTP 404 on chat always means the model is missing, WebStreamRequest
          // drops the body so the message is just "HTTP 404"
          if Pos('HTTP 404', ErrMsg) > 0 then
            ErrMsg := 'Model "' + FAgent.ModelName + '" is not available on the server. ' +
              'Run "models" to list installed models, or "ollama pull ' + FAgent.ModelName + '" to download it.';
          // Add an actionable hint for the most common context error
          if Pos('context length', LowerCase(ErrMsg)) > 0 then
            ErrMsg := ErrMsg + LineEnding + 'hint: use "cls" to clear history, or "set numctx <larger>" to raise the window';
          FAgent.LogLine(Format('Abort: chat error kind=%d attempt=%d response_len=%d request_bytes=%d msg="%s"',
            [Ord(Kind), Attempt, Length(FinalJson), Length(MessagesJson), ErrMsg]));
          Exit;
        end;

        // Update usage counters from the manager after each step
        FAgent.FContextUsed := FAgent.OllamaManager.LastUsageTotal;
        // Resolve context total from NumCtx or from loaded model info
        if FAgent.OllamaManager.NumCtx > 0 then
          FAgent.FContextTotal := FAgent.OllamaManager.NumCtx
        else
        begin
          // Try the real value first, then fall back to a safe estimate
          ResolvedCtx := FAgent.OllamaManager.GetModelContextLength(FAgent.ModelName);
          if ResolvedCtx > 0 then
            FAgent.FContextTotal := ResolvedCtx
          else if FAgent.FContextTotal = 0 then
            // Model not loaded yet, assume a common 8K window so percent is meaningful
            FAgent.FContextTotal := 8192;
          FAgent.LogLine(Format('Resolved context_length=%d for "%s"', [FAgent.FContextTotal, FAgent.ModelName]));
        end;

        FAgent.LogLine(Format('Chat done raw_len=%d usage=%d/%d', [Length(FinalJson), FAgent.FContextUsed,
          FAgent.FContextTotal]));

        Data := nil;
        try
          try
            Data := GetJSON(FinalJson);
          except
            Data := nil;
          end;
          if (Data = nil) or (Data.JSONType <> jtObject) then
          begin
            Reason := afrError;
            ErrMsg := 'Invalid JSON from LLM';
            Exit;
          end;

          MessageData := TJSONObject(Data).Find('message');
          if MessageData <> nil then
            MessagesArr.Add(MessageData.Clone);

          ToolCallsArr := nil;
          ToolCallsData := nil;
          if (MessageData <> nil) and (MessageData.JSONType = jtObject) then
          begin
            ToolCallsData := TJSONObject(MessageData).Find('tool_calls');
            if (ToolCallsData <> nil) and (ToolCallsData.JSONType = jtArray) then
              ToolCallsArr := TJSONArray(ToolCallsData);
          end;

          // Retry the request when the model returns an empty response, prompting it to try a different approach
          if (ToolCallsArr = nil) or (ToolCallsArr.Count = 0) then
          begin
            if (MessageData <> nil) and (MessageData.JSONType = jtObject) then
              FinalContent := TJSONObject(MessageData).Get('content', '');
            if FinalContent = '' then
              FinalContent := FCurrentContent;

            if Trim(FinalContent) = '' then
            begin
              Inc(EmptyResponseRetries);
              FAgent.LogLine(Format('Empty response, retry %d of %d', [EmptyResponseRetries, MAX_EMPTY_RESPONSE_RETRIES]));

              if EmptyResponseRetries <= MAX_EMPTY_RESPONSE_RETRIES then
              begin
                MsgObj := TJSONObject.Create;
                MsgObj.Add('role', 'user');
                MsgObj.Add('content',
                  'Your previous response was completely empty. The task is not completed. ' +
                  'Review the conversation and try a different approach. ' +
                  'If a file or directory was not found, inspect other directories and search the workspace more broadly. ' +
                  'Do not repeat the same unsuccessful search.');
                MessagesArr.Add(MsgObj);
                FinalContent := '';
                Continue;
              end;

              Reason := afrError;
              ErrMsg := 'The model returned an empty response after multiple retries';
              FAgent.LogLine('Abort: ' + ErrMsg);
              Exit;
            end;

            // Content is already emitted by ChatStream or ChatWithTools callbacks
            FAgent.LogLine(Format('Finished: content_len=%d tool_calls=0', [Length(FinalContent)]));
            Reason := afrSuccess;
            Exit;
          end;

          FAgent.LogLine(Format('ToolCalls count=%d', [ToolCallsArr.Count]));

          // Parse all tool calls first so they can be emitted and run as a batch
          ToolCount := ToolCallsArr.Count;
          SetLength(ToolNames, ToolCount);
          SetLength(ToolArgArr, ToolCount);
          SetLength(ToolAllowArr, ToolCount);
          SetLength(ToolResultArr, ToolCount);
          AllParallelSafe := ToolCount > 1;
          for ToolIdx := 0 to ToolCount - 1 do
          begin
            ToolNames[ToolIdx] := '';
            ToolArgArr[ToolIdx] := '{}';
            ToolAllowArr[ToolIdx] := False;
            ToolResultArr[ToolIdx] := '';

            ToolCallObj := ToolCallsArr.Objects[ToolIdx];
            if ToolCallObj = nil then
            begin
              AllParallelSafe := False;
              Continue;
            end;

            FuncData := ToolCallObj.Find('function');
            if (FuncData = nil) or (FuncData.JSONType <> jtObject) then
            begin
              AllParallelSafe := False;
              Continue;
            end;
            FuncObj := TJSONObject(FuncData);

            ToolNames[ToolIdx] := FuncObj.Get('name', '');
            ArgsData := FuncObj.Find('arguments');
            if ArgsData = nil then
              ToolArgArr[ToolIdx] := '{}'
            else if ArgsData.JSONType = jtString then
              ToolArgArr[ToolIdx] := TJSONString(ArgsData).AsString
            else
              ToolArgArr[ToolIdx] := ArgsData.AsJSON;

            QueueToolCall(ToolNames[ToolIdx], ToolArgArr[ToolIdx]);

            // finish and non-safe tools break the parallel batch
            if (ToolNames[ToolIdx] = 'finish') or not IsParallelSafeTool(ToolNames[ToolIdx]) then
              AllParallelSafe := False;
          end;

          // Route checks are always sequential, host may deny per call
          for ToolIdx := 0 to ToolCount - 1 do
          begin
            if ToolNames[ToolIdx] = '' then
              Continue;
            QueueRoute(aoToolCall, ToolNames[ToolIdx] + ' ' + ToolArgArr[ToolIdx], Allow);
            ToolAllowArr[ToolIdx] := Allow;
          end;

          // Execute: parallel for safe batches, sequential otherwise
          if AllParallelSafe then
          begin
            if FAgent.FCancelled then
            begin
              Reason := afrCancelled;
              Exit;
            end;
            FAgent.LogLine(Format('Running %d tools in parallel', [ToolCount]));
            Threads := TList.Create;
            try
              // Create worker threads for allowed and valid calls
              for ToolIdx := 0 to ToolCount - 1 do
              begin
                if ToolNames[ToolIdx] = '' then
                  Continue;
                if not ToolAllowArr[ToolIdx] then
                begin
                  ToolResultArr[ToolIdx] := '{"error": "denied by host"}';
                  Continue;
                end;
                Threads.Add(TToolExecThread.Create(FAgent, ToolNames[ToolIdx], ToolArgArr[ToolIdx]));
              end;
              for ToolIdx := 0 to Threads.Count - 1 do
                TToolExecThread(Threads[ToolIdx]).WaitFor;
              // Collect results in original order
              CollectIdx := 0;
              for ToolIdx := 0 to ToolCount - 1 do
              begin
                if ToolNames[ToolIdx] = '' then
                  Continue;
                if ToolAllowArr[ToolIdx] then
                begin
                  ToolResultArr[ToolIdx] := TToolExecThread(Threads[CollectIdx]).ToolResult;
                  Inc(CollectIdx);
                end;
              end;
            finally
              // Free worker objects even when an exception interrupted the batch
              for ToolIdx := 0 to Threads.Count - 1 do
                TToolExecThread(Threads[ToolIdx]).Free;
              Threads.Free;
            end;
          end
          else
          begin
            for ToolIdx := 0 to ToolCount - 1 do
            begin
              if FAgent.FCancelled then
              begin
                Reason := afrCancelled;
                Exit;
              end;
              if ToolNames[ToolIdx] = '' then
                Continue;

              if not ToolAllowArr[ToolIdx] then
              begin
                ToolResultArr[ToolIdx] := '{"error": "denied by host"}';
                Continue;
              end;

              // finish tool only signals completion, the answer is in streamed content
              if (ToolNames[ToolIdx] = 'finish') and (afFinish in FAgent.FFeatures) then
              begin
                FinalContent := FCurrentContent;
                FAgent.LogLine('Finished: explicit finish tool called');
                Reason := afrSuccess;
                Exit;
              end;

              ToolResultArr[ToolIdx] := FAgent.DispatchTool(ToolNames[ToolIdx], ToolArgArr[ToolIdx]);
            end;
          end;

          // Emit results in original order and append tool messages
          for ToolIdx := 0 to ToolCount - 1 do
          begin
            if ToolNames[ToolIdx] = '' then
              Continue;
            QueueToolResult(ToolNames[ToolIdx], ToolResultArr[ToolIdx]);
            MsgObj := TJSONObject.Create;
            MsgObj.Add('role', 'tool');
            MsgObj.Add('content', ToolResultArr[ToolIdx]);
            MessagesArr.Add(MsgObj);
          end;
        finally
          Data.Free;
        end;
      end;

      Reason := afrMaxSteps;
    except
      on E: Exception do
      begin
        Reason := afrError;
        ErrMsg := E.Message;
        FAgent.LogLine(Format('Exception %s: %s', [E.ClassName, E.Message]));
      end;
    end;
  finally
    if FinalContent = '' then
      FinalContent := FCurrentContent;
    FAgent.FFinalAnswer := FinalContent;
    if FAgent.KeepHistory then
    begin
      try
        // Resolve orphaned tool calls for both cancelled and error paths,
        // otherwise the next run sends assistant tool_calls without replies
        if (Reason = afrCancelled) or (Reason = afrError) then
        begin
          if (MessagesArr.Count > 0) and (MessagesArr.Items[MessagesArr.Count - 1].JSONType = jtObject) then
          begin
            Data := TJSONObject(MessagesArr.Items[MessagesArr.Count - 1]).Find('tool_calls');
            if (Data <> nil) and (Data.JSONType = jtArray) then
            begin
              for I := 0 to TJSONArray(Data).Count - 1 do
              begin
                MsgObj := TJSONObject.Create;
                MsgObj.Add('role', 'tool');
                if Reason = afrCancelled then
                  MsgObj.Add('content', '{"error": "cancelled by user before execution"}')
                else
                  MsgObj.Add('content', '{"error": "aborted by error before execution"}');
                MessagesArr.Add(MsgObj);
              end;
            end;
            // Do not free Data, it is owned by the parent message object
            Data := nil;
          end;
        end;
        // Close a cancelled turn with partial content and a cancel marker
        if Reason = afrCancelled then
        begin
          MsgObj := TJSONObject.Create;
          MsgObj.Add('role', 'assistant');
          if FinalContent <> '' then
            MsgObj.Add('content', FinalContent + #10#10 +
              '[cancelled by user, partial answer above may be incomplete, user may refer to it]')
          else
            MsgObj.Add('content', '[cancelled by user before any answer was produced, user may refer to this request]');
          MessagesArr.Add(MsgObj);
        end;
        // Strip leading system message, it is rebuilt on each run
        if (MessagesArr.Count > 0) and (MessagesArr.Items[0].JSONType = jtObject) and
          (TJSONObject(MessagesArr.Items[0]).Get('role', '') = 'system') then
          MessagesArr.Delete(0);
        FAgent.FHistory := MessagesArr.AsJSON;
      except
        ; // Ignore history save errors
      end;
    end;
    MessagesArr.Free;
    QueueFinish(Reason, FAgent.FFinalAnswer, ErrMsg);
    // Consume the prelude so it is not reused by the next run
    FAgent.FContextPrelude := '';
    FAgent.FDone := True;
  end;
end;

{ TAgentTools }

constructor TAgentTools.Create(AOwner: TCustomOllamaAgent);
begin
  inherited Create(TAgentTool);
  FOwner := AOwner;
end;

function TAgentTools.GetOwner: TPersistent;
begin
  Result := FOwner;
end;

function TAgentTools.GetItem(AIndex: integer): TAgentTool;
begin
  Result := TAgentTool(inherited Items[AIndex]);
end;

procedure TAgentTools.SetItem(AIndex: integer; const AValue: TAgentTool);
begin
  inherited SetItem(AIndex, AValue);
end;

function TAgentTools.Add: TAgentTool;
begin
  Result := TAgentTool(inherited Add);
end;

{ TCustomOllamaAgent }

constructor TCustomOllamaAgent.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FModelName := '';
  FSystemPrompt := '';
  FMaxSteps := 20;
  FRequestTimeout := 0;
  FFeatures := [afFileTools];
  FStreaming := True;
  FRootPath := '';
  FKeepHistory := False;
  FHistory := '';
  FDone := True;
  FCancelled := False;
  FFinalAnswer := '';
  FLog := False;
  FLogToolResult := True;
  FOnLog := nil;
  FContextUsed := 0;
  FContextTotal := 0;
  FOnAskUser := nil;
  FExecShellInfo := '';
  FLoadAgentsMd := True;
  FAgentsFileName := 'AGENTS.md';
  FAllowAccessToSystem := True;
  FBlockSensitiveFiles := True;
  FCapabilitiesCache := TStringList.Create;
  FCapabilitiesCache.NameValueSeparator := '=';
  FTools := TAgentTools.Create(Self);
  FWebOptions := TAgentWebOptions.Create;
end;

destructor TCustomOllamaAgent.Destroy;
begin
  // Wait for any running thread to finish
  while not FDone do
    CheckSynchronize(50);
  // Drain any queued events so they do not fire after Free
  CheckSynchronize(0);
  FCapabilitiesCache.Free;
  FWebOptions.Free;
  FTools.Free;
  inherited Destroy;
end;

procedure TCustomOllamaAgent.SetOllamaManager(const AValue: TOllamaManager);
begin
  if FOllamaManager = AValue then
    Exit;
  if Assigned(FOllamaManager) then
    FOllamaManager.RemoveFreeNotification(Self);
  FOllamaManager := AValue;
  if Assigned(FOllamaManager) then
    FOllamaManager.FreeNotification(Self);
end;

procedure TCustomOllamaAgent.SetTools(const AValue: TAgentTools);
begin
  FTools.Assign(AValue);
end;

procedure TCustomOllamaAgent.SetWebOptions(const AValue: TAgentWebOptions);
begin
  FWebOptions.Assign(AValue);
end;

procedure TCustomOllamaAgent.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FOllamaManager) then
    FOllamaManager := nil;
end;

function TCustomOllamaAgent.GetRootPath: string;
begin
  Result := FRootPath;
end;

procedure TCustomOllamaAgent.SetRootPath(const AValue: string);
begin
  if FRootPath = AValue then
    Exit;
  FRootPath := AValue;
end;

function TCustomOllamaAgent.GetHistory: string;
begin
  Result := FHistory;
end;

procedure TCustomOllamaAgent.SetHistory(const AValue: string);
begin
  FHistory := AValue;
end;

procedure TCustomOllamaAgent.RunAsync(const AText: string);
begin
  if not FDone then
    Exit;
  FDone := False;
  FCancelled := False;
  FFinalAnswer := '';
  FContextUsed := 0;
  // Only apply explicit override here, model query happens in worker thread
  if Assigned(FOllamaManager) and (FOllamaManager.NumCtx > 0) then
    FContextTotal := FOllamaManager.NumCtx
  else
    FContextTotal := 0;
  TOllamaAgentThread.Create(Self, AText);
end;

function TCustomOllamaAgent.Run(const AText: string): string;
begin
  RunAsync(AText);
  while not FDone do
    CheckSynchronize(50);
  CheckSynchronize(0);
  Result := FFinalAnswer;
end;

procedure TCustomOllamaAgent.Cancel;
begin
  FCancelled := True;
end;

procedure TCustomOllamaAgent.ClearHistory;
begin
  FHistory := '';
end;

function TCustomOllamaAgent.BuildSystemPrompt: string;
const
  MAX_AGENTS_BYTES = 16384;
var
  ToolList, PlatformName, EnvironmentBlock, ShellDesc: string;
  AgentsPath, AgentsContent: string;
begin
  // Resolve user-provided placeholders first
  Result := string(FSystemPrompt);
  Result := StringReplace(Result, '{path}', GetEffectiveRootPath, [rfReplaceAll]);
  Result := StringReplace(Result, '{model}', FModelName, [rfReplaceAll]);
  ToolList := BuildToolsNames;
  if ToolList = '' then
    ToolList := 'none';
  Result := StringReplace(Result, '{tools}', ToolList, [rfReplaceAll]);
  // Drop trailing whitespace so the environment block starts on a clean line
  Result := TrimRight(Result);

  // Platform identity is compiled in, not guessed at runtime
  {$IFDEF WINDOWS}
  PlatformName := 'Windows';
  {$ELSE}
  {$IFDEF LINUX}
    PlatformName := 'Linux';
  {$ELSE}
  {$IFDEF DARWIN}
      PlatformName := 'macOS';
  {$ELSE}
  PlatformName := 'Unix-like';
  {$ENDIF}
  {$ENDIF}
  {$ENDIF}

  // Append environment facts the model can rely on, host-neutral wording
  EnvironmentBlock :=
    'Environment facts:' + LineEnding + '- Platform: ' + PlatformName + LineEnding + '- Path delimiter: "' +
    PathDelim + '"' + LineEnding + '- Workspace root: ' + GetEffectiveRootPath + LineEnding +
    '- The workspace root may change during the session. Always re-check file ' +
    'existence after any directory change with a fresh tool call, results from ' + 'previous locations may be stale.' + LineEnding;

  // The actual shell behind exec_command when known, else platform default
  if Trim(FExecShellInfo) <> '' then
    ShellDesc := Trim(FExecShellInfo)
  else
  begin
    {$IFDEF WINDOWS}
    ShellDesc := 'cmd.exe';
    {$ELSE}
    ShellDesc := '/bin/sh';
    {$ENDIF}
  end;
  EnvironmentBlock := EnvironmentBlock + '- Shell for exec_command: ' + ShellDesc + LineEnding;

  // Platform-specific shell notes, factual and short
  {$IFDEF WINDOWS}
  EnvironmentBlock := EnvironmentBlock +
    '- Use "nul" instead of "/dev/null" to discard output, ";" does not chain commands, use "&&".' + LineEnding;
  {$ELSE}
  EnvironmentBlock := EnvironmentBlock + '- Use "/dev/null" to discard output, ";" and "&&" both chain commands.' + LineEnding;
  {$ENDIF}

  // Universal rules: prefer dedicated tools over shell for file work
  EnvironmentBlock := EnvironmentBlock + '- Do NOT redirect listing or search output to files with ">", use list_files, find_files ' +
    'or grep tools instead. Those tools return results directly and do not pollute the workspace.' + LineEnding;
  EnvironmentBlock := EnvironmentBlock + '- File tool paths are relative to the workspace root, never absolute paths.' + LineEnding;
  Result := Result + #10#10 + EnvironmentBlock;

  // Append the workspace root instruction file when present
  if FLoadAgentsMd then
  begin
    AgentsPath := IncludeTrailingPathDelimiter(GetEffectiveRootPath) + FAgentsFileName;
    if FileExists(AgentsPath) then
    begin
      if ReadTextFileSafe(AgentsPath, AgentsContent) then
      begin
        AgentsContent := TrimRight(AgentsContent);
        if Length(AgentsContent) > MAX_AGENTS_BYTES then
          AgentsContent := Copy(AgentsContent, 1, MAX_AGENTS_BYTES) + LineEnding + '[... truncated at ' +
            IntToStr(MAX_AGENTS_BYTES) + ' bytes]';
        if AgentsContent <> '' then
        begin
          Result := Result + #10#10 + 'Project instructions from ' + FAgentsFileName + ':' + LineEnding + AgentsContent;
          LogLine(Format('Loaded %s, %d bytes', [FAgentsFileName, Length(AgentsContent)]));
        end;
      end;
    end;
    Result := Result + #10 + 'Subdirectories may have their own ' + FAgentsFileName +
      '. Use read_agents_md with a path to load the local rules before editing files there.';
  end;

  // Append authoritative tool list so the model cannot claim disabled tools
  if ToolList = 'none' then
    Result := Result + #10 + 'IMPORTANT: no tools are currently enabled. You cannot run shell commands, ' +
      'read or write files, list directories, search the workspace, access the ' +
      'internet, or call any other external function. If the user asks for such ' +
      'actions, explain that no tools are enabled and ask them to enable the ' + 'corresponding feature in the agent settings.'
  else
    Result := Result + #10 + 'IMPORTANT: the only tools currently enabled are: ' + ToolList + '. ' +
      'You must not claim access to any tool that is not in this list. ' +
      'If the user asks for an action that requires an unavailable tool, ' + 'explain that the tool is not enabled.';
  // Enforce file reading strategy when the tools are available
  if Pos('read_file_preview', ToolList) > 0 then
    Result := Result + #10 + 'When exploring an unknown file or a file larger than 50 KB, ALWAYS call ' +
      'read_file_preview first to see its size, structure and first/last lines. ' +
      'Only then decide whether to read the whole file with read_file or specific ' + 'ranges with read_file_lines.';
  if Pos('read_file_lines', ToolList) > 0 then
    Result := Result + #10 + 'When read_file returns a truncation notice, use read_file_lines with ' +
      'start_line and end_line to read further parts of the file in chunks. ' +
      'Do not give up on large files, read them in sections until you have the ' + 'content you need.';
end;

procedure TCustomOllamaAgent.RefreshContextInfo;
var
  ResolvedCtx: int64;
begin
  FContextTotal := 0;
  if not Assigned(FOllamaManager) then
    Exit;
  if Trim(FModelName) = '' then
    Exit;
  if FOllamaManager.NumCtx > 0 then
  begin
    FContextTotal := FOllamaManager.NumCtx;
    Exit;
  end;
  ResolvedCtx := FOllamaManager.GetModelContextLength(FModelName);
  if ResolvedCtx > 0 then
    FContextTotal := ResolvedCtx;
end;

procedure TCustomOllamaAgent.ResetUsage;
begin
  // Only usage is reset, context total comes from model and stays unchanged
  FContextUsed := 0;
  if Assigned(FOllamaManager) then
    FOllamaManager.ResetUsage;
end;

function TCustomOllamaAgent.GetContextPercent: integer;
begin
  if (FContextTotal > 0) and (FContextUsed > 0) then
  begin
    Result := Round(FContextUsed * 100.0 / FContextTotal);
    if Result > 100 then
      Result := 100;
  end
  else
    Result := 0;
end;

function TCustomOllamaAgent.GetContextUsedKb: integer;
begin
  // Shown as KB in prompt, means thousands of tokens
  Result := FContextUsed div 1024;
end;

function TCustomOllamaAgent.GetContextTotalKb: integer;
begin
  // Shown as KB in prompt, means thousands of tokens
  Result := FContextTotal div 1024;
end;

procedure TCustomOllamaAgent.DoLog(const AText: string);
var
  Call: TLogCall;
begin
  // Main thread logs synchronously so lines keep their order
  if GetCurrentThreadID = MainThreadID then
  begin
    if Assigned(FOnLog) then
    begin
      try
        FOnLog(Self, AText);
      except
        ; // Host handler raised, ignore to keep the agent consistent
      end;
    end
    else
    begin
      WriteLn(ErrOutput, AText);
      Flush(ErrOutput);
    end;
    Exit;
  end;
  Call := TLogCall.Create;
  Call.Agent := Self;
  Call.Text := AText;
  TThread.Queue(nil, @Call.Invoke);
end;

procedure TCustomOllamaAgent.LogLine(const AText: string);
begin
  if not FLog then
    Exit;
  DoLog('[agent] ' + AText);
end;

procedure TCustomOllamaAgent.EmitToolResult(const AName, AResult: string);
const
  // Preview size, longer outputs are truncated with " ..."
  PREVIEW_CHARS = 500;
var
  Display: string;
begin
  if not FLogToolResult then
    Exit;
  Display := AResult;
  Display := StringReplace(Display, #13#10, ' ', [rfReplaceAll]);
  Display := StringReplace(Display, #10, ' ', [rfReplaceAll]);
  Display := StringReplace(Display, #13, ' ', [rfReplaceAll]);
  if Length(Display) > PREVIEW_CHARS then
    Display := Copy(Display, 1, PREVIEW_CHARS) + ' ...';
  DoLog('  [' + AName + '] ' + Display);
  // Separate the preview from the next block (thinking or another tool call)
  DoLog('');
end;

function TCustomOllamaAgent.GetEffectiveRootPath: string;
begin
  if FRootPath <> '' then
    Result := ExpandFileName(FRootPath)
  else
    Result := GetCurrentDir;
end;

function TCustomOllamaAgent.SafePath(const ARelPath: string): string;
var
  Root, Full, Normalized: string;
begin
  Result := '';
  Root := IncludeTrailingPathDelimiter(GetEffectiveRootPath);
  // Normalize forward slashes so absolute detection works on Windows
  Normalized := StringReplace(Trim(ARelPath), '/', PathDelim, [rfReplaceAll]);
  // Collapse duplicate separators for local paths, preserve UNC prefix
  if (Length(Normalized) >= 2) and ((Normalized[1] <> PathDelim) or (Normalized[2] <> PathDelim)) then
    while Pos(PathDelim + PathDelim, Normalized) > 0 do
      Normalized := StringReplace(Normalized, PathDelim + PathDelim, PathDelim, [rfReplaceAll]);
  if Normalized = '' then
    Exit(Root);
  // Absolute paths are resolved as-is, not prefixed with Root
  if IsPathAbsolute(Normalized) then
    Full := ExpandFileName(Normalized)
  else
    Full := ExpandFileName(Root + Normalized);
  // Sandbox mode, path must stay inside RootPath, compare with trailing
  // delimiter so '.' resolves to root itself
  if (not FAllowAccessToSystem) and (Pos(LowerCase(Root), LowerCase(IncludeTrailingPathDelimiter(Full))) <> 1) then
    Exit;
  // Sensitive file protection applies in both modes
  if FBlockSensitiveFiles and IsSensitiveFile(Full) then
    Exit;
  Result := Full;
end;

function TCustomOllamaAgent.SafePathError: string;
begin
  if FAllowAccessToSystem then
    Result := '{"error": "path is blocked, it matches a sensitive file pattern"}'
  else
    Result := '{"error": "path outside workspace or blocked, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
end;

function TCustomOllamaAgent.ModelSupportsTools(out AErrorMsg: string): boolean;
var
  Kind: TOllamaErrorKind;
  ShowErr, Json: string;
  Data, Caps: TJSONData;
  Arr: TJSONArray;
  I, Idx: integer;
  HasTools: boolean;
  CapsStr: string;
begin
  Result := True;
  AErrorMsg := '';
  if not Assigned(FOllamaManager) then
    Exit;
  if Trim(FModelName) = '' then
    Exit;
  Idx := FCapabilitiesCache.IndexOfName(FModelName);
  if Idx >= 0 then
  begin
    Result := FCapabilitiesCache.ValueFromIndex[Idx] = '1';
    if not Result then
      AErrorMsg := 'Model "' + FModelName + '" does not support tool calling. ' +
        'Switch to a tool-capable model or run "set tools none".';
    Exit;
  end;
  Json := FOllamaManager.ShowModel(FModelName, Kind, ShowErr);
  if Kind <> oekNone then
  begin
    // Explicit 404 from /api/show means the model is not on the server
    if Kind = oekNotFound then
    begin
      Result := False;
      AErrorMsg := 'Model "' + FModelName + '" is not available on the server. ' +
        'Run "models" to list installed models, or "ollama pull ' + FModelName + '" to download it.';
      Exit;
    end;
    // Transient errors (connection, timeout, server 5xx) leave Result = True
    Exit;
  end;
  Data := nil;
  try
    try
      Data := GetJSON(Json);
    except
      Data := nil;
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit;
    Caps := TJSONObject(Data).Find('capabilities');
    if (Caps = nil) or (Caps.JSONType <> jtArray) then
      Exit;
    Arr := TJSONArray(Caps);
    if Arr.Count = 0 then
      Exit;
    CapsStr := '';
    HasTools := False;
    for I := 0 to Arr.Count - 1 do
    begin
      if Arr.Strings[I] = 'tools' then
        HasTools := True;
      if CapsStr <> '' then
        CapsStr := CapsStr + ', ';
      CapsStr := CapsStr + Arr.Strings[I];
    end;
    if HasTools then
      FCapabilitiesCache.Values[FModelName] := '1'
    else
      FCapabilitiesCache.Values[FModelName] := '0';
    Result := HasTools;
    if not HasTools then
      AErrorMsg := 'Model "' + FModelName + '" does not support tool calling (capabilities: ' + CapsStr +
        '). Switch to a tool-capable model or run "set tools none".';
  finally
    Data.Free;
  end;
end;

function TCustomOllamaAgent.SummarizeMessages(const AMessagesJson: string): string;
var
  Kind: TOllamaErrorKind;
  ErrMsg, SummJson: string;
  SummArr: TJSONArray;
  SysMsg, UserMsg: TJSONObject;
  SavedTimeout: integer;
begin
  Result := '';
  if not Assigned(FOllamaManager) then
    Exit;
  SummArr := TJSONArray.Create;
  try
    SysMsg := TJSONObject.Create;
    SysMsg.Add('role', 'system');
    SysMsg.Add('content', 'You are a conversation summarizer. Compress the provided ' +
      'conversation into a compact summary. Preserve: user goals, key facts, files ' +
      'modified, decisions made, remaining tasks. Drop: redundant tool output, ' +
      'greetings, intermediate reasoning. Write in the user''s language. Aim for 10-20% ' +
      'of the original length. Output only the summary.');
    SummArr.Add(SysMsg);
    UserMsg := TJSONObject.Create;
    UserMsg.Add('role', 'user');
    UserMsg.Add('content', 'Summarize this conversation:' + #10 + AMessagesJson);
    SummArr.Add(UserMsg);
    SummJson := SummArr.AsJSON;
  finally
    SummArr.Free;
  end;
  LogLine(Format('Summarizing conversation, input_len=%d', [Length(AMessagesJson)]));
  // Apply the agent-level timeout override during summarization
  SavedTimeout := FOllamaManager.RequestTimeout;
  if FRequestTimeout > 0 then
    FOllamaManager.RequestTimeout := FRequestTimeout;
  try
    Result := FOllamaManager.ChatWithTools(FModelName, SummJson, '', Kind, ErrMsg);
  finally
    FOllamaManager.RequestTimeout := SavedTimeout;
  end;
  if Kind <> oekNone then
  begin
    LogLine('Summarize failed: ' + ErrMsg);
    Result := '';
  end;
end;

function TCustomOllamaAgent.BuildToolsSchemaJson: string;

  procedure AddTool(AArr: TJSONArray; const AName, ADesc, AParamsJson: string);
  var
    ToolObj, FuncObj: TJSONObject;
    Params: TJSONData;
  begin
    ToolObj := TJSONObject.Create;
    ToolObj.Add('type', 'function');
    FuncObj := TJSONObject.Create;
    FuncObj.Add('name', AName);
    FuncObj.Add('description', ADesc);
    Params := nil;
    try
      try
        Params := GetJSON(AParamsJson);
      except
        Params := nil;
      end;
      if Params = nil then
      begin
        Params := TJSONObject.Create;
        TJSONObject(Params).Add('type', 'object');
        TJSONObject(Params).Add('properties', TJSONObject.Create);
      end;
      FuncObj.Add('parameters', Params);
    except
      Params.Free;
    end;
    ToolObj.Add('function', FuncObj);
    AArr.Add(ToolObj);
  end;

var
  Arr: TJSONArray;
  I: integer;
  ToolObj, FuncObj: TJSONObject;
  Params: TJSONData;
begin
  Result := '';
  Arr := TJSONArray.Create;
  try
    for I := 0 to FTools.Count - 1 do
    begin
      ToolObj := TJSONObject.Create;
      ToolObj.Add('type', 'function');
      FuncObj := TJSONObject.Create;
      FuncObj.Add('name', FTools[I].Name);
      FuncObj.Add('description', string(FTools[I].Description));
      Params := nil;
      try
        try
          Params := GetJSON(string(FTools[I].ParametersJson));
        except
          Params := nil;
        end;
        if Params = nil then
        begin
          Params := TJSONObject.Create;
          TJSONObject(Params).Add('type', 'object');
          TJSONObject(Params).Add('properties', TJSONObject.Create);
        end;
        FuncObj.Add('parameters', Params);
      except
        Params.Free;
      end;
      ToolObj.Add('function', FuncObj);
      Arr.Add(ToolObj);
    end;

    if afFileTools in FFeatures then
    begin
      AddTool(Arr, 'read_file_preview',
        'Preview a text file: first and last N lines plus total size. ' +
        'Call FIRST on unknown or large (>50KB) files before read_file.',
        '{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"},"head":{"type":"integer","description":"First lines, default 30, max 500"},"tail":{"type":"integer","description":"Last lines, default 30, max 500"}},"required":["path"]}');
      AddTool(Arr, 'read_file_lines',
        'Read a line range. Use for files >50KB or after read_file truncation. ' +
        'Up to 5000 lines per call, use increasing start_line for large files.',
        '{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":"integer","description":"First line, 1-based"},"end_line":{"type":"integer","description":"Last line, inclusive"}},"required":["path"]}');
      AddTool(Arr, 'read_file',
        'Read file contents. Default max_bytes=50000. Use max_bytes=0 only for small files, ' +
        'prefer read_file_preview or read_file_lines for large ones. Set allow_binary=true only when binary data must be read as text.',
        '{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"},"max_bytes":{"type":"integer","description":"Max bytes, default 50000, 0=whole file"},"allow_binary":{"type":"boolean","description":"Allow reading binary files as text, default false"}},"required":["path"]}');
      AddTool(Arr, 'write_file', 'Write contents to a file, creates parent directories',
        '{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}');
      AddTool(Arr, 'list_files',
        'List files in a directory, non-recursive. Returns {files: [...], agents_md?: "name"} ' +
        'when a local ' + FAgentsFileName + ' exists in that directory.',
        '{"type":"object","properties":{"path":{"type":"string","description":"Optional relative directory"}}}');
      AddTool(Arr, 'search_text', 'Search for a literal text pattern, returns file and line',
        '{"type":"object","properties":{"path":{"type":"string"},"pattern":{"type":"string"},"recursive":{"type":"boolean"}},"required":["pattern"]}');
      AddTool(Arr, 'edit_file',
        'Replace exact string in a file. old_string must occur exactly once unless replace_all=true',
        '{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["path","old_string","new_string"]}');
      AddTool(Arr, 'delete_file', 'Delete a file',
        '{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}');
      AddTool(Arr, 'move_file', 'Move or rename a file',
        '{"type":"object","properties":{"source":{"type":"string"},"destination":{"type":"string"}},"required":["source","destination"]}');
      AddTool(Arr, 'copy_file', 'Copy a file',
        '{"type":"object","properties":{"source":{"type":"string"},"destination":{"type":"string"}},"required":["source","destination"]}');
      AddTool(Arr, 'file_info', 'Size, modification time and type of a file or directory',
        '{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}');
      AddTool(Arr, 'create_directory', 'Create a directory and all parent directories',
        '{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}');
      AddTool(Arr, 'find_files',
        'Find files by glob (* and ?). Recursive by default, do NOT add ** prefix. ' +
        '[abc] classes unsupported. Capped at 2000 results.',
        '{"type":"object","properties":{"path":{"type":"string"},"pattern":{"type":"string"},"recursive":{"type":"boolean"}},"required":["pattern"]}');
      AddTool(Arr, 'grep',
        'Search file contents, capped at 500 matches. Literal by default, but patterns ' +
        'starting with ^ or ending with $ or containing \\w, \\d or | (alternation) are ' +
        'automatically treated as regex. Skips .git/node_modules/bin/obj. ' + 'Returns file, line, text per match.',
        '{"type":"object","properties":{"path":{"type":"string","description":"File or directory, default workspace root"},"pattern":{"type":"string"},"recursive":{"type":"boolean","description":"Recurse, default true"},"literal":{"type":"boolean","description":"Force literal match, bypassing auto-regex detection"}},"required":["pattern"]}');
      AddTool(Arr, 'read_agents_md',
        'Read the nearest ' + FAgentsFileName + ' for the given path, walking up to the workspace root. ' +
        'Returns {found, path, content}. Use before editing files to learn local conventions.',
        '{"type":"object","properties":{"path":{"type":"string","description":"File or directory, default workspace root"}}}');
    end;

    if afExecCommand in FFeatures then
      AddTool(Arr, 'exec_command',
        'Execute a shell command in the current workspace and return combined stdout and stderr. ' +
        'The command runs in the host shell (see the environment description for the exact shell ' +
        'and its rules). Redirect with > and >>. Prefer portable commands where possible. ' +
        'See the environment description for OS-specific notes, path syntax and forbidden utilities.',
        '{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}');

    if afGit in FFeatures then
    begin
      AddTool(Arr, 'git_status', 'Show working tree status as porcelain output',
        '{"type":"object","properties":{}}');
      AddTool(Arr, 'git_diff', 'Show diff of working tree, optionally limited to one path',
        '{"type":"object","properties":{"path":{"type":"string"}}}');
      AddTool(Arr, 'git_log', 'Show recent commit history as one-line log',
        '{"type":"object","properties":{"limit":{"type":"integer","description":"Number of commits, default 20"}}}');
      AddTool(Arr, 'git_commit', 'Stage all changes and create a commit with the given message',
        '{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}');
    end;

    if afInteractive in FFeatures then
      AddTool(Arr, 'ask_user', 'Ask the user a question and wait for the answer before continuing',
        '{"type":"object","properties":{"question":{"type":"string"}},"required":["question"]}');

    if afFinish in FFeatures then
      AddTool(Arr, 'finish',
        'Declare the task complete. Put the full final answer in the regular message content BEFORE calling this tool. This tool takes no arguments and only signals completion.',
        '{"type":"object","properties":{}}');

    if afWebTools in FFeatures then
    begin
      AddTool(Arr, 'web_fetch', 'Fetch content of an http or https URL using GET, returns plain text or HTML stripped',
        '{"type":"object","properties":{"url":{"type":"string","description":"Full URL including scheme"}},"required":["url"]}');
      AddTool(Arr, 'web_search', 'Search the web using the configured search engine and return results page text',
        '{"type":"object","properties":{"query":{"type":"string","description":"Search query"}},"required":["query"]}');
    end;

    if Arr.Count > 0 then
      Result := Arr.AsJSON;
  finally
    Arr.Free;
  end;
end;

function TCustomOllamaAgent.BuildToolsNames: string;
var
  Names: TStringList;
  I: integer;
begin
  Names := TStringList.Create;
  try
    for I := 0 to FTools.Count - 1 do
      Names.Add(FTools[I].Name);
    if afFileTools in FFeatures then
    begin
      Names.Add('read_file_preview');
      Names.Add('read_file_lines');
      Names.Add('read_file');
      Names.Add('write_file');
      Names.Add('list_files');
      Names.Add('search_text');
      Names.Add('edit_file');
      Names.Add('delete_file');
      Names.Add('move_file');
      Names.Add('copy_file');
      Names.Add('file_info');
      Names.Add('create_directory');
      Names.Add('find_files');
      Names.Add('grep');
      Names.Add('read_agents_md');
    end;
    if afExecCommand in FFeatures then
      Names.Add('exec_command');
    if afGit in FFeatures then
    begin
      Names.Add('git_status');
      Names.Add('git_diff');
      Names.Add('git_log');
      Names.Add('git_commit');
    end;
    if afInteractive in FFeatures then
      Names.Add('ask_user');
    if afFinish in FFeatures then
      Names.Add('finish');
    if afWebTools in FFeatures then
    begin
      Names.Add('web_fetch');
      Names.Add('web_search');
    end;
    Result := Names.CommaText;
  finally
    Names.Free;
  end;
end;

function TCustomOllamaAgent.BuildFileNotFoundError(const AFullPath, ARelPath: string): string;
const
  MAX_SUGGESTIONS = 3;
  MAX_DISTANCE = 3;
var
  Dir, BaseName, SuggestNames: string;
  Info: TSearchRec;
  Res, Dist, I, J: integer;
  Candidates: TStringList;
  Dists: array of integer = nil;
  TmpName: string;
  TmpDist: integer;
begin
  Dir := ExtractFileDir(AFullPath);
  BaseName := ExtractFileName(AFullPath);
  Candidates := TStringList.Create;
  try
    if DirectoryExists(Dir) then
    begin
      Res := FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, Info);
      if Res = 0 then
      try
        repeat
          if (Info.Name <> '.') and (Info.Name <> '..') and ((Info.Attr and faDirectory) = 0) then
          begin
            Dist := LevenshteinDistance(LowerCase(BaseName), LowerCase(Info.Name));
            if (Dist > 0) and (Dist <= MAX_DISTANCE) then
            begin
              Candidates.Add(Info.Name);
              SetLength(Dists, Candidates.Count);
              Dists[Candidates.Count - 1] := Dist;
            end;
          end;
        until FindNext(Info) <> 0;
      finally
        FindClose(Info);
      end;
    end;

    // Bubble sort by distance, list is tiny
    for I := 0 to Candidates.Count - 2 do
      for J := 0 to Candidates.Count - 2 - I do
        if Dists[J] > Dists[J + 1] then
        begin
          TmpName := Candidates[J];
          Candidates[J] := Candidates[J + 1];
          Candidates[J + 1] := TmpName;
          TmpDist := Dists[J];
          Dists[J] := Dists[J + 1];
          Dists[J + 1] := TmpDist;
        end;

    SuggestNames := '';
    for I := 0 to Min(Candidates.Count, MAX_SUGGESTIONS) - 1 do
    begin
      if SuggestNames <> '' then
        SuggestNames := SuggestNames + ', ';
      SuggestNames := SuggestNames + '"' + Candidates[I] + '"';
    end;

    Result := '{"error": "file not found: ' + TJSONString.Create(ARelPath).AsJSON;
    if SuggestNames <> '' then
      Result := Result + ', "did_you_mean": [' + SuggestNames + ']';
    Result := Result + '}';
  finally
    Candidates.Free;
  end;
end;

function TCustomOllamaAgent.DoReadFile(AArgs: TJSONObject): string;
const
  DEFAULT_MAX_BYTES = 50000;
  // Hard cap for max_bytes=0 to protect memory on accidental huge files
  HARD_LIMIT_BYTES = 16 * 1024 * 1024;
var
  RelPath, FullPath: string;
  Content, Suffix: string;
  ReadCount, FullSize: int64;
  MaxBytes: int64;
  TotalLines, I, LinesShown: integer;
  AllowBinary: boolean;
begin
  Result := '{"error": "invalid arguments"}';
  Content := '';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  // Model may emit {"": "path"} or {"filename": "path"} when confused
  if (RelPath = '') and (AArgs.Count = 1) and (AArgs.Names[0] = '') then
    RelPath := AArgs.Items[0].AsString;
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := SafePathError;
    Exit;
  end;
  if DirectoryExists(FullPath) then
  begin
    Result := '{"error": "path is a directory, use list_files to see its contents"}';
    Exit;
  end;
  if not FileExists(FullPath) then
  begin
    Result := BuildFileNotFoundError(FullPath, RelPath);
    Exit;
  end;
  AllowBinary := GetBoolArg(AArgs, 'allow_binary', False);
  if not AllowBinary and IsBinaryFile(FullPath) then
  begin
    Result := '{"error": "binary file detected, set allow_binary=true to read it as text"}';
    Exit;
  end;
  MaxBytes := GetIntArg(AArgs, 'max_bytes', DEFAULT_MAX_BYTES);
  // Negative values fall back to default, 0 means whole file up to the hard cap
  if MaxBytes < 0 then
    MaxBytes := DEFAULT_MAX_BYTES;
  if (MaxBytes = 0) or (MaxBytes > HARD_LIMIT_BYTES) then
    MaxBytes := HARD_LIMIT_BYTES;
  // Unified read, byte-capped before decoding
  if not ReadTextFileSafe(FullPath, Content, feAuto, 0, -1, MaxBytes, TotalLines, ReadCount, FullSize) then
  begin
    Result := '{"error": "cannot read file"}';
    Exit;
  end;
  // Tell the model how much was shown and where to continue
  if FullSize > ReadCount then
  begin
    LinesShown := 0;
    for I := 1 to Length(Content) do
      if Content[I] = #10 then
        Inc(LinesShown);
    Suffix := #10#10 + '[file truncated: showed ' + IntToStr(ReadCount) + ' of ' + IntToStr(FullSize) +
      ' bytes (' + IntToStr(LinesShown) + ' lines, applied max_bytes=' + IntToStr(MaxBytes) + '). ' +
      'Use read_file_lines with start_line=' + IntToStr(LinesShown + 1) + ' to continue reading from where this message left off, ' +
      'or call read_file again with a larger max_bytes value if the file is small]';
    Content := Content + Suffix;
  end;
  Result := TJSONString.Create(Content).AsJSON;
end;

function TCustomOllamaAgent.DoReadFilePreview(AArgs: TJSONObject): string;
const
  DEFAULT_HEAD = 30;
  DEFAULT_TAIL = 30;
  MAX_LINES_PER_EDGE = 500;
  MAX_FILE_SIZE_FOR_PREVIEW = 10 * 1024 * 1024;
var
  RelPath, FullPath: string;
  Lines: TStringList;
  TotalLines, HeadCount, TailCount, I, SkippedCount: integer;
  Size, BytesRead: int64;
  Buf: TStringBuilder;
  Stream: TFileStream;
  Content: string;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  // Model may emit {"": "path"} or {"filename": "path"} when confused
  if (RelPath = '') and (AArgs.Count = 1) and (AArgs.Names[0] = '') then
    RelPath := AArgs.Items[0].AsString;
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := SafePathError;
    Exit;
  end;
  if DirectoryExists(FullPath) then
  begin
    Result := '{"error": "path is a directory, use list_files to see its contents"}';
    Exit;
  end;
  if not FileExists(FullPath) then
  begin
    Result := BuildFileNotFoundError(FullPath, RelPath);
    Exit;
  end;
  Stream := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyNone);
  try
    Size := Stream.Size;
  finally
    Stream.Free;
  end;
  // Preview is meant for quick inspection, refuse absurdly large files
  if Size > MAX_FILE_SIZE_FOR_PREVIEW then
  begin
    Result := '{"error": "file too large for preview (' + IntToStr(Size) +
      ' bytes), use read_file_lines with start_line and end_line"}';
    Exit;
  end;
  if IsBinaryFile(FullPath) then
  begin
    Result := '{"error": "binary file detected, use read_file with allow_binary=true if needed"}';
    Exit;
  end;
  HeadCount := integer(GetIntArg(AArgs, 'head', DEFAULT_HEAD));
  TailCount := integer(GetIntArg(AArgs, 'tail', DEFAULT_TAIL));
  if HeadCount < 1 then
    HeadCount := DEFAULT_HEAD;
  if HeadCount > MAX_LINES_PER_EDGE then
    HeadCount := MAX_LINES_PER_EDGE;
  if TailCount < 0 then
    TailCount := DEFAULT_TAIL;
  if TailCount > MAX_LINES_PER_EDGE then
    TailCount := MAX_LINES_PER_EDGE;
  // Unified read, encoding auto-detected
  if not ReadTextFileSafe(FullPath, Content, feAuto, 0, -1, 0, TotalLines, BytesRead, Size) then
  begin
    Result := '{"error": "cannot read file"}';
    Exit;
  end;
  Lines := TStringList.Create;
  try
    Lines.Text := Content;
    Buf := TStringBuilder.Create;
    try
      Buf.Append('=== File preview: ' + RelPath + ' ===' + #10);
      Buf.Append(Format('Size: %d bytes, %d lines', [Size, TotalLines]) + #10 + #10);
      if TotalLines <= HeadCount + TailCount then
      begin
        Buf.Append('--- Full content (file is small) ---' + #10);
        for I := 0 to TotalLines - 1 do
        begin
          Buf.Append(Lines[I]);
          Buf.Append(#10);
        end;
      end
      else
      begin
        Buf.Append(Format('--- First %d lines ---', [HeadCount]) + #10);
        for I := 0 to HeadCount - 1 do
        begin
          Buf.Append(Lines[I]);
          Buf.Append(#10);
        end;
        SkippedCount := TotalLines - HeadCount - TailCount;
        Buf.Append(#10);
        Buf.Append(Format('[... %d lines skipped, from line %d to line %d ...]', [SkippedCount, HeadCount +
          1, TotalLines - TailCount]) + #10);
        Buf.Append(#10);
        if TailCount > 0 then
        begin
          Buf.Append(Format('--- Last %d lines ---', [TailCount]) + #10);
          for I := TotalLines - TailCount to TotalLines - 1 do
          begin
            Buf.Append(Lines[I]);
            Buf.Append(#10);
          end;
        end;
      end;
      Buf.Append(#10);
      if Size <= 50000 then
        Buf.Append('This file is ' + IntToStr(Size) + ' bytes, it FITS ENTIRELY in a single ' +
          'read_file call. Use read_file(path) now to load the whole file at once.')
      else
      begin
        Buf.Append('This file is ' + IntToStr(Size) + ' bytes, larger than the 50 KB default. ');
        Buf.Append('Use read_file for the first 50 KB, then read_file_lines with start_line/end_line for more.');
      end;
      Result := TJSONString.Create(Buf.ToString).AsJSON;
    finally
      Buf.Free;
    end;
  finally
    Lines.Free;
  end;
end;

function TCustomOllamaAgent.DoWriteFile(AArgs: TJSONObject): string;
const
  MAX_WRITE_BYTES = 16 * 1024 * 1024;
var
  RelPath, FullPath, Content: string;
  Stream: TFileStream;
  Bytes: TBytes = ();
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  Content := AArgs.Get('content', '');
  if Length(Content) > MAX_WRITE_BYTES then
  begin
    Result := '{"error": "content too large: ' + IntToStr(Length(Content)) + ' bytes, maximum is ' + IntToStr(MAX_WRITE_BYTES) + '"}';
    Exit;
  end;
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := SafePathError;
    Exit;
  end;
  try
    ForceDirectories(ExtractFileDir(FullPath));
    Stream := TFileStream.Create(FullPath, fmCreate);
    try
      if Length(Content) > 0 then
      begin
        // Explicit copy avoids TBytes(string) cast edge cases
        SetLength(Bytes, Length(Content));
        Move(Content[1], Bytes[0], Length(Content));
        Stream.Write(Bytes[0], Length(Bytes));
      end;
    finally
      Stream.Free;
    end;
    Result := '{"ok": true, "bytes": ' + IntToStr(Length(Content)) + '}';
  except
    on E: Exception do
      Result := '{"error": "write failed: ' + StringReplace(E.Message, '"', '\"', [rfReplaceAll]) + '"}';
  end;
end;

function TCustomOllamaAgent.DoListFiles(AArgs: TJSONObject): string;
var
  RelPath, FullPath: string;
  Items: TStringList;
  Info: TSearchRec;
  Arr: TJSONArray;
  I: integer;
begin
  Result := '{"error": "invalid arguments"}';
  RelPath := '';
  if AArgs <> nil then
    RelPath := AArgs.Get('path', '');
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := SafePathError;
    Exit;
  end;
  if not DirectoryExists(FullPath) then
  begin
    Result := '{"error": "directory not found"}';
    Exit;
  end;

  Items := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(FullPath) + '*', faAnyFile, Info) = 0 then
    try
      repeat
        if (Info.Name <> '.') and (Info.Name <> '..') then
        begin
          if (Info.Attr and faDirectory) <> 0 then
            Items.Add(Info.Name + '/')
          else
            Items.Add(Info.Name);
        end;
      until FindNext(Info) <> 0;
    finally
      FindClose(Info);
    end;
    Items.Sort;
    Arr := TJSONArray.Create;
    try
      for I := 0 to Items.Count - 1 do
        Arr.Add(Items[I]);
      // Report local instruction file so the model can load it explicitly
      if FLoadAgentsMd and FileExists(IncludeTrailingPathDelimiter(FullPath) + FAgentsFileName) then
        Result := '{"files": ' + Arr.AsJSON + ', "agents_md": ' + TJSONString.Create(FAgentsFileName).AsJSON + '}'
      else
        Result := '{"files": ' + Arr.AsJSON + '}';
    finally
      Arr.Free;
    end;
  finally
    Items.Free;
  end;
end;

function TCustomOllamaAgent.DoSearchText(AArgs: TJSONObject): string;
const
  MAX_MATCHES = 500;
  MAX_TOTAL_BYTES = 50000;
  MAX_MATCH_LINE_CHARS = 500;
var
  RelPath, FullPath, Pattern, LowPattern: string;
  Recursive: boolean;
  Files: TStringList;
  Matches: TJSONArray;
  FileLines: TStringList;
  I, J, TotalBytes: integer;
  Line: string;
  MatchObj: TJSONObject;
  BaseRoot: string;
  Truncated: boolean;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  Pattern := AArgs.Get('pattern', '');
  Recursive := GetBoolArg(AArgs, 'recursive', True);
  if Pattern = '' then
  begin
    Result := '{"error": "pattern required"}';
    Exit;
  end;
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := SafePathError;
    Exit;
  end;
  if not DirectoryExists(FullPath) then
  begin
    Result := '{"error": "directory not found"}';
    Exit;
  end;
  BaseRoot := IncludeTrailingPathDelimiter(GetEffectiveRootPath);
  LowPattern := LowerCase(Pattern);
  Files := TStringList.Create;
  Matches := TJSONArray.Create;
  Truncated := False;
  TotalBytes := 0;
  try
    FindAllFiles(Files, FullPath, '*.*', Recursive);
    for I := 0 to Files.Count - 1 do
    begin
      if Matches.Count >= MAX_MATCHES then
      begin
        Truncated := True;
        Break;
      end;
      if TotalBytes >= MAX_TOTAL_BYTES then
      begin
        Truncated := True;
        Break;
      end;
      if IsBinaryFile(Files[I]) then
        Continue;
      FileLines := TStringList.Create;
      try
        try
          FileLines.LoadFromFile(Files[I], TEncoding.UTF8);
        except
          try
            FileLines.LoadFromFile(Files[I]);
          except
            Continue;
          end;
        end;
        for J := 0 to FileLines.Count - 1 do
        begin
          if Matches.Count >= MAX_MATCHES then
          begin
            Truncated := True;
            Break;
          end;
          if TotalBytes >= MAX_TOTAL_BYTES then
          begin
            Truncated := True;
            Break;
          end;
          Line := FileLines[J];
          if Pos(LowPattern, LowerCase(Line)) > 0 then
          begin
            if Length(Line) > MAX_MATCH_LINE_CHARS then
              Line := Copy(Line, 1, MAX_MATCH_LINE_CHARS) + '...';
            MatchObj := TJSONObject.Create;
            MatchObj.Add('file', Copy(Files[I], Length(BaseRoot) + 1, MaxInt));
            MatchObj.Add('line', J + 1);
            MatchObj.Add('text', Line);
            Matches.Add(MatchObj);
            Inc(TotalBytes, Length(Line) + 50);
          end;
        end;
      finally
        FileLines.Free;
      end;
    end;
    Result := '{"count": ' + IntToStr(Matches.Count) + ', "truncated": ' + BoolToStr(Truncated, 'true', 'false') +
      ', "matches": ' + Matches.AsJSON + '}';
  finally
    Matches.Free;
    Files.Free;
  end;
end;

function TCustomOllamaAgent.DoReadFileLines(AArgs: TJSONObject): string;
var
  RelPath, FullPath: string;
  Lines: TStringList;
  StartLine, EndLine, TotalLines, I: integer;
  Buf: TStringBuilder;
  Content: string;
  BytesRead, FileSize: int64;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  // Model may emit {"": "path"} or {"filename": "path"} when confused
  if (RelPath = '') and (AArgs.Count = 1) and (AArgs.Names[0] = '') then
    RelPath := AArgs.Items[0].AsString;
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := SafePathError;
    Exit;
  end;
  if DirectoryExists(FullPath) then
  begin
    Result := '{"error": "path is a directory, use list_files to see its contents"}';
    Exit;
  end;
  if not FileExists(FullPath) then
  begin
    Result := BuildFileNotFoundError(FullPath, RelPath);
    Exit;
  end;
  if IsBinaryFile(FullPath) then
  begin
    Result := '{"error": "binary file detected, use read_file with allow_binary=true if needed"}';
    Exit;
  end;
  StartLine := integer(GetIntArg(AArgs, 'start_line', 1));
  EndLine := integer(GetIntArg(AArgs, 'end_line', -1));
  if StartLine < 1 then
    StartLine := 1;
  // Unified read, encoding auto-detected
  if not ReadTextFileSafe(FullPath, Content, feAuto, 0, -1, 0, TotalLines, BytesRead, FileSize) then
  begin
    Result := '{"error": "cannot read file"}';
    Exit;
  end;
  if EndLine < 0 then
    EndLine := TotalLines
  else if EndLine > TotalLines then
    EndLine := TotalLines;
  // Cap at 5000 lines per call
  if EndLine - StartLine + 1 > 5000 then
    EndLine := StartLine + 4999;
  Lines := TStringList.Create;
  try
    Lines.Text := Content;
    Buf := TStringBuilder.Create;
    try
      for I := StartLine - 1 to EndLine - 1 do
      begin
        Buf.Append(Lines[I]);
        if I < EndLine - 1 then
          Buf.Append(LineEnding);
      end;
      Result := '{"content": ' + TJSONString.Create(Buf.ToString).AsJSON + ', "total_lines": ' +
        IntToStr(TotalLines) + ', "shown_from": ' + IntToStr(StartLine) + ', "shown_to": ' + IntToStr(EndLine) + '}';
    finally
      Buf.Free;
    end;
  finally
    Lines.Free;
  end;
end;

function TCustomOllamaAgent.DoEditFile(AArgs: TJSONObject): string;
var
  RelPath, FullPath, Content, OldStr, NewStr: string;
  ReplaceAll: boolean;
  P, SecondPos: integer;
  Count: integer;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  // Model may emit {"": "path"} or {"filename": "path"} when confused
  if (RelPath = '') and (AArgs.Count = 1) and (AArgs.Names[0] = '') then
    RelPath := AArgs.Items[0].AsString;
  OldStr := AArgs.Get('old_string', '');
  NewStr := AArgs.Get('new_string', '');
  ReplaceAll := GetBoolArg(AArgs, 'replace_all', False);
  if OldStr = '' then
  begin
    Result := '{"error": "old_string is required"}';
    Exit;
  end;
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := SafePathError;
    Exit;
  end;
  if not FileExists(FullPath) then
  begin
    Result := BuildFileNotFoundError(FullPath, RelPath);
    Exit;
  end;
  if IsBinaryFile(FullPath) then
  begin
    Result := '{"error": "binary file detected, cannot edit binary files"}';
    Exit;
  end;
  if not ReadTextFileSafe(FullPath, Content) then
  begin
    Result := '{"error": "cannot read file"}';
    Exit;
  end;
  Count := 0;
  if ReplaceAll then
  begin
    P := Pos(OldStr, Content);
    if P = 0 then
    begin
      Result := '{"error": "old_string not found"}';
      Exit;
    end;
    while P > 0 do
    begin
      Inc(Count);
      P := Pos(OldStr, Content, P + Length(OldStr));
    end;
    Content := StringReplace(Content, OldStr, NewStr, [rfReplaceAll]);
  end
  else
  begin
    P := Pos(OldStr, Content);
    if P = 0 then
    begin
      Result := '{"error": "old_string not found"}';
      Exit;
    end;
    SecondPos := Pos(OldStr, Copy(Content, P + 1, MaxInt));
    if SecondPos > 0 then
    begin
      Result := '{"error": "old_string is ambiguous, occurs multiple times, provide more context or set replace_all=true"}';
      Exit;
    end;
    Delete(Content, P, Length(OldStr));
    Insert(NewStr, Content, P);
    Count := 1;
  end;
  if not WriteTextFileSafe(FullPath, Content) then
  begin
    Result := '{"error": "cannot write file"}';
    Exit;
  end;
  Result := '{"ok": true, "replaced": ' + IntToStr(Count) + '}';
end;

function TCustomOllamaAgent.DoDeleteFile(AArgs: TJSONObject): string;
var
  RelPath, FullPath: string;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := SafePathError;
    Exit;
  end;
  if not FileExists(FullPath) then
  begin
    Result := '{"error": "file not found"}';
    Exit;
  end;
  try
    if DeleteFile(FullPath) then
      Result := '{"ok": true}'
    else
      Result := '{"error": "delete failed, file may be locked"}';
  except
    on E: Exception do
      Result := '{"error": "' + StringReplace(E.Message, '"', '\"', [rfReplaceAll]) + '"}';
  end;
end;

function TCustomOllamaAgent.DoMoveFile(AArgs: TJSONObject): string;
var
  SrcRel, DstRel, SrcFull, DstFull: string;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  SrcRel := AArgs.Get('source', '');
  DstRel := AArgs.Get('destination', '');
  SrcFull := SafePath(SrcRel);
  DstFull := SafePath(DstRel);
  if (SrcFull = '') or (DstFull = '') then
  begin
    Result := SafePathError;
    Exit;
  end;
  if not FileExists(SrcFull) then
  begin
    Result := '{"error": "source not found"}';
    Exit;
  end;
  if FileExists(DstFull) then
  begin
    Result := '{"error": "destination already exists, delete it first or choose another name"}';
    Exit;
  end;
  ForceDirectories(ExtractFileDir(DstFull));
  try
    if RenameFile(SrcFull, DstFull) then
      Result := '{"ok": true}'
    else
      Result := '{"error": "move failed"}';
  except
    on E: Exception do
      Result := '{"error": "' + StringReplace(E.Message, '"', '\"', [rfReplaceAll]) + '"}';
  end;
end;

function TCustomOllamaAgent.DoCopyFile(AArgs: TJSONObject): string;
var
  SrcRel, DstRel, SrcFull, DstFull: string;
  Stream: TFileStream;
  Size: int64;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  SrcRel := AArgs.Get('source', '');
  DstRel := AArgs.Get('destination', '');
  SrcFull := SafePath(SrcRel);
  DstFull := SafePath(DstRel);
  if (SrcFull = '') or (DstFull = '') then
  begin
    Result := SafePathError;
    Exit;
  end;
  if not FileExists(SrcFull) then
  begin
    Result := '{"error": "source not found"}';
    Exit;
  end;
  ForceDirectories(ExtractFileDir(DstFull));
  try
    Stream := TFileStream.Create(SrcFull, fmOpenRead or fmShareDenyNone);
    try
      Size := Stream.Size;
    finally
      Stream.Free;
    end;
    if CopyFile(SrcFull, DstFull, False) then
      Result := '{"ok": true, "bytes": ' + IntToStr(Size) + '}'
    else
      Result := '{"error": "copy failed"}';
  except
    on E: Exception do
      Result := '{"error": "' + StringReplace(E.Message, '"', '\"', [rfReplaceAll]) + '"}';
  end;
end;

function TCustomOllamaAgent.DoFileInfo(AArgs: TJSONObject): string;
var
  RelPath, FullPath: string;
  IsDir: boolean;
  Size: int64;
  MTime: TDateTime;
  Info: TSearchRec;
  Res: integer;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := SafePathError;
    Exit;
  end;
  Res := FindFirst(FullPath, faAnyFile, Info);
  if Res <> 0 then
  begin
    Result := '{"exists": false}';
    Exit;
  end;
  try
    IsDir := (Info.Attr and faDirectory) <> 0;
    Size := Info.Size;
    MTime := FileDateToDateTime(Info.Time);
  finally
    FindClose(Info);
  end;
  Result := '{"exists": true, "is_directory": ' + BoolToStr(IsDir, 'true', 'false') + ', "size": ' +
    IntToStr(Size) + ', "modified": "' + FormatDateTime('yyyy-mm-dd hh:nn:ss', MTime) + '"}';
end;

function TCustomOllamaAgent.DoCreateDirectory(AArgs: TJSONObject): string;
var
  RelPath, FullPath: string;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := SafePathError;
    Exit;
  end;
  if DirectoryExists(FullPath) then
  begin
    Result := '{"ok": true, "already_existed": true}';
    Exit;
  end;
  try
    ForceDirectories(FullPath);
    Result := '{"ok": true}';
  except
    on E: Exception do
      Result := '{"error": "' + StringReplace(E.Message, '"', '\"', [rfReplaceAll]) + '"}';
  end;
end;

function TCustomOllamaAgent.DoFindFiles(AArgs: TJSONObject): string;
const
  MAX_RESULTS = 2000;
  MAX_TOTAL_BYTES = 50000;
var
  RelPath, FullPath, Pattern, NormPattern: string;
  Recursive: boolean;
  Files: TStringList;
  Patterns: TStringList;
  Arr: TJSONArray;
  I, P, TotalBytes: integer;
  BaseRoot: string;
  Truncated: boolean;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  Pattern := AArgs.Get('pattern', '*');
  Recursive := GetBoolArg(AArgs, 'recursive', True);
  if Pattern = '' then
    Pattern := '*';
  if Pattern = '' then
    Pattern := '*';
  // Handle recursive glob prefix before splitting the path and mask
  if (Copy(Pattern, 1, 3) = '**/') or (Copy(Pattern, 1, 3) = '**\') then
  begin
    Delete(Pattern, 1, 3);
    Recursive := True;
  end;
  // Accept path-style patterns like "src/*.pas" by merging them into the search root
  P := LastDelimiter('/' + PathDelim, Pattern);
  if P > 0 then
  begin
    if RelPath <> '' then
      RelPath := IncludeTrailingPathDelimiter(RelPath) + Copy(Pattern, 1, P - 1)
    else
      RelPath := Copy(Pattern, 1, P - 1);
    Pattern := Copy(Pattern, P + 1, MaxInt);
    if Pattern = '' then
      Pattern := '*';
  end;
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := SafePathError;
    Exit;
  end;
  if not DirectoryExists(FullPath) then
  begin
    Result := '{"error": "directory not found"}';
    Exit;
  end;
  BaseRoot := IncludeTrailingPathDelimiter(GetEffectiveRootPath);
  Files := TStringList.Create;
  Files.Sorted := True;
  Files.Duplicates := dupIgnore;
  Arr := TJSONArray.Create;
  Patterns := ExpandBracePatterns(Pattern);
  try
    // Run FindAllFiles once per expanded pattern, Files dedupes results
    for P := 0 to Patterns.Count - 1 do
    begin
      NormPattern := NormalizeGlobPattern(Patterns[P]);
      if NormPattern <> '' then
        FindAllFiles(Files, FullPath, NormPattern, Recursive);
    end;
    Files.Sort;
    TotalBytes := 0;
    Truncated := False;
    for I := 0 to Files.Count - 1 do
    begin
      if Arr.Count >= MAX_RESULTS then
      begin
        Truncated := True;
        Break;
      end;
      if TotalBytes >= MAX_TOTAL_BYTES then
      begin
        Truncated := True;
        Break;
      end;
      // Explicit find_files must see all files, gitignore filtering is for grep only
      RelPath := RelativeToRoot(BaseRoot, Files[I]);
      if IsJunkFileForFind(RelPath) then
        Continue;
      Arr.Add(RelPath);
      Inc(TotalBytes, Length(RelPath) + 4);
    end;
    Result := '{"count": ' + IntToStr(Arr.Count) + ', "truncated": ' + BoolToStr(Truncated, 'true', 'false') +
      ', "files": ' + Arr.AsJSON + '}';
  finally
    Patterns.Free;
    Arr.Free;
    Files.Free;
  end;
end;

function TCustomOllamaAgent.DoGrep(AArgs: TJSONObject): string;
const
  MAX_MATCHES = 500;
  MAX_FILE_SIZE = 1024 * 1024;
  MAX_FILES_SCANNED = 2000;
  // Wall-clock budget for a single grep call to protect the agent loop
  MAX_GREP_MS = 10000;
  // Byte and per-line caps for the total response to the model
  MAX_TOTAL_BYTES = 50000;
  MAX_MATCH_LINE_CHARS = 300;
var
  RelPath, FullPath, Pattern, IncludePattern, Content: string;
  Recursive, Literal, LiteralExplicit, AutoRegex, SingleFile, ScanLimited: boolean;
  Files: TStringList;
  Matches: TJSONArray;
  I, FilesScanned: integer;
  BaseRoot: string;
  Regex: TRegExpr;
  GitPatterns: TStringList;
  StartTick: QWord;
  TimedOut: boolean;
  TotalBytes: integer;

// Returns True for VCS, build output and package caches to skip
  function IsJunkPath(const ARelPath: string): boolean;
  var
    Low: string;
  begin
    Low := '/' + LowerCase(StringReplace(ARelPath, '\\', '/', [rfReplaceAll])) + '/';
    Result := (Pos('/.git/', Low) > 0) or (Pos('/.svn/', Low) > 0) or (Pos('/.hg/', Low) > 0) or
      (Pos('/node_modules/', Low) > 0) or (Pos('/__pycache__/', Low) > 0) or (Pos('/bin/', Low) > 0) or
      (Pos('/obj/', Low) > 0) or (Pos('/.vs/', Low) > 0) or (Pos('/.idea/', Low) > 0) or (Pos('/dist/', Low) > 0) or
      (Pos('/build/', Low) > 0) or (Pos('/target/', Low) > 0);
  end;

  // Scans one file, appending matches to the shared Matches array
  procedure ScanFile(const AFullPath, ARelPath: string);
  var
    Lines: TStringList;
    J: integer;
    Line: string;
    MatchObj: TJSONObject;
    FR: TSearchRec;
    HasMatch: boolean;
  begin
    if Matches.Count >= MAX_MATCHES then
      Exit;
    if FindFirst(AFullPath, faAnyFile, FR) = 0 then
    try
      if FR.Size > MAX_FILE_SIZE then
        Exit;
    finally
      FindClose(FR);
    end;

    if IsBinaryFile(AFullPath) then
      Exit;

    Lines := TStringList.Create;
    try
      if not ReadTextFileSafe(AFullPath, Content) then
        Exit;
      Lines.Text := Content;

      for J := 0 to Lines.Count - 1 do
      begin
        if Matches.Count >= MAX_MATCHES then
          Break;
        if TotalBytes >= MAX_TOTAL_BYTES then
          Break;
        Line := Lines[J];
        if Literal then
          HasMatch := Pos(Pattern, Line) > 0
        else
        begin
          try
            HasMatch := Regex.Exec(Line);
          except
            HasMatch := False;
          end;
        end;
        if HasMatch then
        begin
          if Length(Line) > MAX_MATCH_LINE_CHARS then
            Line := Copy(Line, 1, MAX_MATCH_LINE_CHARS) + '... [truncated]';
          MatchObj := TJSONObject.Create;
          MatchObj.Add('file', ARelPath);
          MatchObj.Add('line', J + 1);
          MatchObj.Add('text', Line);
          Matches.Add(MatchObj);
          Inc(TotalBytes, Length(ARelPath) + Length(Line) + 30);
        end;
      end;
    finally
      Lines.Free;
    end;
  end;

begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  Pattern := AArgs.Get('pattern', '');
  IncludePattern := Trim(AArgs.Get('include', ''));
  if Pattern = '' then
  begin
    Result := '{"error": "pattern required"}';
    Exit;
  end;
  RelPath := AArgs.Get('path', '');
  Recursive := GetBoolArg(AArgs, 'recursive', True);
  // Auto-enable regex mode when pattern clearly uses regex syntax
  LiteralExplicit := AArgs.Find('literal') <> nil;
  Literal := GetBoolArg(AArgs, 'literal', True);
  AutoRegex := False;
  if Literal and not LiteralExplicit and PatternLooksLikeRegex(Pattern) then
  begin
    Literal := False;
    AutoRegex := True;
  end;
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := SafePathError;
    Exit;
  end;
  if not FileExists(FullPath) and not DirectoryExists(FullPath) then
  begin
    Result := '{"error": "path is neither a file nor a directory"}';
    Exit;
  end;
  BaseRoot := IncludeTrailingPathDelimiter(GetEffectiveRootPath);
  Regex := nil;
  if not Literal then
  begin
    Regex := TRegExpr.Create;
    try
      Regex.Expression := Pattern;
      // Trigger compilation on empty string to surface syntax errors early
      Regex.Exec('');
    except
      on E: Exception do
      begin
        Regex.Free;
        Result := '{"error": "invalid regex: ' + TJSONString.Create(E.Message).AsJSON +
          '", "hint": "set literal=true to search for the exact string"}';
        Exit;
      end;
    end;
  end;
  Files := TStringList.Create;
  Matches := TJSONArray.Create;
  GitPatterns := LoadGitignorePatterns(GetEffectiveRootPath);
  ScanLimited := False;
  FilesScanned := 0;
  TimedOut := False;
  TotalBytes := 0;
  StartTick := GetTickCount64;
  try
    // A path to a file searches only that file, like Unix grep file.txt
    SingleFile := FileExists(FullPath) and not DirectoryExists(FullPath);
    if SingleFile then
    begin
      if (IncludePattern = '') or MatchesMask(ExtractFileName(FullPath), IncludePattern) then
      begin
        Inc(FilesScanned);
        ScanFile(FullPath, RelativeToRoot(BaseRoot, FullPath));
      end;
    end
    else
    begin
      FindAllFiles(Files, FullPath, '*.*', Recursive);
      for I := 0 to Files.Count - 1 do
      begin
        if Matches.Count >= MAX_MATCHES then
          Break;
        if TotalBytes >= MAX_TOTAL_BYTES then
        begin
          ScanLimited := True;
          Break;
        end;
        if FilesScanned >= MAX_FILES_SCANNED then
        begin
          ScanLimited := True;
          Break;
        end;
        // Abort the whole scan when the time budget is exhausted
        if GetTickCount64 - StartTick >= MAX_GREP_MS then
        begin
          ScanLimited := True;
          TimedOut := True;
          Break;
        end;
        RelPath := RelativeToRoot(BaseRoot, Files[I]);
        if IsJunkPath(RelPath) or IsIgnoredByGitignore(RelPath, GitPatterns) then
          Continue;
        if (IncludePattern <> '') and not MatchesMask(ExtractFileName(Files[I]), IncludePattern) then
          Continue;
        Inc(FilesScanned);
        ScanFile(Files[I], RelPath);
      end;
      if (not TimedOut) and (FilesScanned >= MAX_FILES_SCANNED) then
        ScanLimited := True;
    end;
    Result := '{"count": ' + IntToStr(Matches.Count) + ', "truncated": ' + BoolToStr(Matches.Count >= MAX_MATCHES, 'true', 'false') +
      ', "scanned_files": ' + IntToStr(FilesScanned) + ', "scan_limited": ' + BoolToStr(ScanLimited, 'true', 'false') +
      ', "timed_out": ' + BoolToStr(TimedOut, 'true', 'false');
    if AutoRegex then
      Result := Result + ', "auto_regex": true';
    Result := Result + ', "matches": ' + Matches.AsJSON + '}';
  finally
    Matches.Free;
    Files.Free;
    GitPatterns.Free;
    if Regex <> nil then
      Regex.Free;
  end;
end;

function TCustomOllamaAgent.DoReadAgentsMd(AArgs: TJSONObject): string;
const
  MAX_AGENTS_BYTES = 16384;
  MAX_SEARCH_DEPTH = 8;
var
  RelPath, SearchPath, FilePath, Content, Root: string;
  Depth: integer;
  FoundPath: string;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  Root := IncludeTrailingPathDelimiter(GetEffectiveRootPath);
  // Normalize input to a directory, treat files as their parent directory
  SearchPath := StringReplace(Trim(RelPath), '/', PathDelim, [rfReplaceAll]);
  if SearchPath = '' then
    SearchPath := Root
  else
  begin
    if IsPathAbsolute(SearchPath) then
      SearchPath := ExpandFileName(SearchPath)
    else
      SearchPath := ExpandFileName(Root + SearchPath);
    if FileExists(SearchPath) then
      SearchPath := ExtractFileDir(SearchPath);
  end;
  // Refuse paths outside the workspace
  if Pos(LowerCase(Root), LowerCase(IncludeTrailingPathDelimiter(SearchPath))) <> 1 then
  begin
    Result := SafePathError;
    Exit;
  end;
  // Walk up the tree for the nearest AGENTS.md within the workspace
  FoundPath := '';
  for Depth := 0 to MAX_SEARCH_DEPTH do
  begin
    FilePath := IncludeTrailingPathDelimiter(SearchPath) + FAgentsFileName;
    if FileExists(FilePath) then
    begin
      FoundPath := FilePath;
      Break;
    end;
    if SameText(ExcludeTrailingPathDelimiter(SearchPath), ExcludeTrailingPathDelimiter(Root)) then
      Break;
    SearchPath := ExcludeTrailingPathDelimiter(ExtractFileDir(SearchPath));
    if (SearchPath = '') or not DirectoryExists(SearchPath) then
      Break;
  end;
  if FoundPath = '' then
  begin
    Result := '{"found": false, "note": "no ' + FAgentsFileName + ' found for "' + RelPath + '" within the workspace"}';
    Exit;
  end;
  if IsBinaryFile(FoundPath) then
  begin
    Result := '{"found": true, "path": ' + TJSONString.Create(RelativeToRoot(Root, FoundPath)).AsJSON +
      ', "error": "binary file detected"}';
    Exit;
  end;
  if not ReadTextFileSafe(FoundPath, Content) then
  begin
    Result := '{"found": true, "path": ' + TJSONString.Create(RelativeToRoot(Root, FoundPath)).AsJSON +
      ', "error": "cannot read file"}';
    Exit;
  end;
  Content := TrimRight(Content);
  if Length(Content) > MAX_AGENTS_BYTES then
    Content := Copy(Content, 1, MAX_AGENTS_BYTES) + LineEnding + '[... truncated at ' + IntToStr(MAX_AGENTS_BYTES) + ' bytes]';
  Result := '{"found": true, "path": ' + TJSONString.Create(RelativeToRoot(Root, FoundPath)).AsJSON +
    ', "content": ' + TJSONString.Create(Content).AsJSON + '}';
end;

function TCustomOllamaAgent.DoGitCommand(const AFullCommand: string): string;
var
  Call: TExecCommandCall;
  Res: string;
  Allow: boolean;
begin
  Result := '{"error": "no OnExecCommand handler, cannot run git"}';
  if not Assigned(FOnExecCommand) then
    Exit;
  LogLine(Format('GitCommand cmd="%s"', [AFullCommand]));
  Call := TExecCommandCall.Create;
  try
    Call.Agent := Self;
    Call.Command := AFullCommand;
    Call.Allow := True;
    Call.Result := '';
    TThread.Synchronize(nil, @Call.Invoke);
    Allow := Call.Allow;
    Res := Call.Result;
  finally
    Call.Free;
  end;
  if Allow then
    Result := Res
  else
    Result := '{"error": "git command denied by host"}';
end;

function TCustomOllamaAgent.DoGitStatus(AArgs: TJSONObject): string;
begin
  Result := DoGitCommand('git status --porcelain');
end;

function TCustomOllamaAgent.DoGitDiff(AArgs: TJSONObject): string;
var
  RelPath, Cmd: string;
begin
  RelPath := '';
  if AArgs <> nil then
    RelPath := AArgs.Get('path', '');
  if RelPath = '' then
    Cmd := 'git diff'
  else
    Cmd := 'git diff -- "' + StringReplace(RelPath, '"', '\"', [rfReplaceAll]) + '"';
  Result := DoGitCommand(Cmd);
end;

function TCustomOllamaAgent.DoGitLog(AArgs: TJSONObject): string;
var
  Limit: integer;
  Cmd: string;
begin
  Limit := integer(GetIntArg(AArgs, 'limit', 20));
  if Limit < 1 then
    Limit := 1;
  if Limit > 200 then
    Limit := 200;
  Cmd := Format('git log --oneline -n %d', [Limit]);
  Result := DoGitCommand(Cmd);
end;

function TCustomOllamaAgent.DoGitCommit(AArgs: TJSONObject): string;
var
  CommitMsg, Cmd, EscapedMsg: string;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  CommitMsg := AArgs.Get('message', '');
  if CommitMsg = '' then
  begin
    Result := '{"error": "message required"}';
    Exit;
  end;
  // Escape double quotes for cmd.exe: wrap in double quotes, replace " with ""
  EscapedMsg := StringReplace(CommitMsg, '"', '""', [rfReplaceAll]);
  Cmd := 'git add -A && git commit -m "' + EscapedMsg + '"';
  Result := DoGitCommand(Cmd);
end;

function TCustomOllamaAgent.DoAskUser(AArgs: TJSONObject): string;
var
  Call: TAskUserCall;
  Question, Answer: string;
  Allow: boolean;
begin
  Result := '{"error": "no OnAskUser handler"}';
  if not Assigned(FOnAskUser) then
    Exit;
  Question := '';
  if AArgs <> nil then
    Question := AArgs.Get('question', '');
  if Question = '' then
  begin
    Result := '{"error": "question required"}';
    Exit;
  end;
  LogLine(Format('AskUser question="%s"', [Copy(Question, 1, 200)]));
  Call := TAskUserCall.Create;
  try
    Call.Agent := Self;
    Call.Question := Question;
    Call.Answer := '';
    Call.Allow := True;
    TThread.Synchronize(nil, @Call.Invoke);
    Allow := Call.Allow;
    Answer := Call.Answer;
  finally
    Call.Free;
  end;
  if Allow then
    Result := '{"answer": ' + TJSONString.Create(Answer).AsJSON + '}'
  else
    Result := '{"error": "user cancelled the question"}';
end;

function TCustomOllamaAgent.CheckUrlSafety(const AUrl: string; out AErrorMsg: string): boolean;
var
  Host: string;
begin
  Result := False;
  AErrorMsg := '';
  if not IsSafeHttpUrl(AUrl, Host) then
  begin
    AErrorMsg := 'only http and https urls are allowed';
    Exit;
  end;
  // Whitelist takes priority when configured
  if FWebOptions.AllowedHosts.Count > 0 then
  begin
    if FWebOptions.AllowedHosts.IndexOf(Host) < 0 then
    begin
      AErrorMsg := 'host not in allowed list: ' + Host;
      Exit;
    end;
  end;
  if FWebOptions.BlockLocalhost and IsLocalhostAddress(Host) then
  begin
    AErrorMsg := 'localhost access is blocked: ' + Host;
    Exit;
  end;
  if FWebOptions.BlockPrivateIPs and IsPrivateAddress(Host) then
  begin
    AErrorMsg := 'private address access is blocked: ' + Host;
    Exit;
  end;
  Result := True;
end;

function TCustomOllamaAgent.DoWebFetchInternal(const AUrl: string; out AContent, AErrorMsg: string): boolean;
var
  Headers, Cookies, ResponseHeaders: TStringList;
  Err: boolean;
  Tm: TTimeout;
begin
  Result := False;
  AContent := '';
  AErrorMsg := '';
  Headers := TStringList.Create;
  Cookies := TStringList.Create;
  ResponseHeaders := nil;
  try
    try
      // Synapse timeouts apply to each send and recv operation, no external abort
      Tm.Connection := FWebOptions.RequestTimeout;
      Tm.Request := FWebOptions.RequestTimeout;
      AContent := TNetwork.WebRequest(wmGet, AUrl, '', Headers, FWebOptions.UserAgent, '',
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', False, Default(TProxy), Tm,
        Cookies, ResponseHeaders, Err);
      if Err then
      begin
        AErrorMsg := 'http request failed: ' + Copy(AContent, 1, 300);
        AContent := '';
        Exit;
      end;
      Result := True;
    except
      on E: Exception do
      begin
        AErrorMsg := 'request error: ' + E.Message;
        AContent := '';
        Result := False;
      end;
    end;
  finally
    Headers.Free;
    Cookies.Free;
    ResponseHeaders.Free;
  end;
end;

function TCustomOllamaAgent.DoWebFetch(AArgs: TJSONObject): string;
var
  Url, Content, ErrorMsg: string;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  Url := Trim(AArgs.Get('url', ''));
  if Url = '' then
  begin
    Result := '{"error": "url required"}';
    Exit;
  end;
  if not CheckUrlSafety(Url, ErrorMsg) then
  begin
    Result := '{"error": ' + TJSONString.Create(ErrorMsg).AsJSON + '}';
    Exit;
  end;
  // Skip request entirely when cancellation is already requested
  if FCancelled then
  begin
    Result := '{"error": "cancelled by user"}';
    Exit;
  end;
  LogLine(Format('WebFetch url="%s"', [Copy(Url, 1, 200)]));
  if not DoWebFetchInternal(Url, Content, ErrorMsg) then
  begin
    Result := '{"error": ' + TJSONString.Create(ErrorMsg).AsJSON + '}';
    Exit;
  end;
  if Length(Content) > FWebOptions.MaxResponseBytes then
    Content := Copy(Content, 1, FWebOptions.MaxResponseBytes) + #10 + '[truncated to ' +
      IntToStr(FWebOptions.MaxResponseBytes) + ' bytes]';
  if FWebOptions.StripHtml then
    Content := StripHtmlTags(Content);
  Result := '{"url": ' + TJSONString.Create(Url).AsJSON + ', "content": ' + TJSONString.Create(Content).AsJSON + '}';
end;

function TCustomOllamaAgent.DoWebSearch(AArgs: TJSONObject): string;
var
  Query, Template, Url, Content, ErrorMsg: string;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  Query := Trim(AArgs.Get('query', ''));
  if Query = '' then
  begin
    Result := '{"error": "query required"}';
    Exit;
  end;
  Template := FWebOptions.SearchUrl;
  if Template = '' then
  begin
    Result := '{"error": "search url not configured"}';
    Exit;
  end;
  Url := StringReplace(Template, '{query}', UrlEncode(Query), [rfReplaceAll]);
  // Apply the same safety checks as web_fetch, search URL comes from config
  if not CheckUrlSafety(Url, ErrorMsg) then
  begin
    Result := '{"error": ' + TJSONString.Create(ErrorMsg).AsJSON + '}';
    Exit;
  end;
  // Skip request entirely when cancellation is already requested
  if FCancelled then
  begin
    Result := '{"error": "cancelled by user"}';
    Exit;
  end;
  LogLine(Format('WebSearch query="%s" url="%s"', [Copy(Query, 1, 100), Copy(Url, 1, 200)]));
  if not DoWebFetchInternal(Url, Content, ErrorMsg) then
  begin
    Result := '{"error": ' + TJSONString.Create(ErrorMsg).AsJSON + '}';
    Exit;
  end;
  if Length(Content) > FWebOptions.MaxResponseBytes then
    Content := Copy(Content, 1, FWebOptions.MaxResponseBytes) + #10 + '[truncated to ' +
      IntToStr(FWebOptions.MaxResponseBytes) + ' bytes]';
  if FWebOptions.StripHtml then
    Content := StripHtmlTags(Content);
  Result := '{"query": ' + TJSONString.Create(Query).AsJSON + ', "content": ' + TJSONString.Create(Content).AsJSON + '}';
end;

function TCustomOllamaAgent.DispatchTool(const AName, AArgsJson: string): string;
var
  I, P: integer;
  Args: TJSONObject;
  Call: TExecCommandCall;
  Command, Res, CleanName: string;
  Allow: boolean;
begin
  // Some models append <tool_call> or whitespace to the function name, strip it
  CleanName := AName;
  P := Pos('<', CleanName);
  if P > 0 then
    CleanName := Copy(CleanName, 1, P - 1);
  CleanName := Trim(CleanName);
  if CleanName = '' then
    CleanName := AName;
  LogLine(Format('DispatchTool name="%s" args="%s"', [CleanName, Copy(AArgsJson, 1, 200)]));

  // Reject malformed JSON before attempting to parse tool arguments
  if not AArgsJson.IsJson then
    Exit('{"error": "tool arguments are not valid JSON"}');

  Args := nil;
  try
    try
      Args := GetJSON(AArgsJson) as TJSONObject;
    except
      Args := nil;
    end;

    // User-defined tools first
    for I := 0 to FTools.Count - 1 do
    begin
      if FTools[I].Name = CleanName then
      begin
        Result := '';
        if Assigned(FTools[I].FOnExecute) then
          FTools[I].FOnExecute(Self, AArgsJson, Result);
        Exit;
      end;
    end;

    if afFileTools in FFeatures then
    begin
      if CleanName = 'read_file' then
        Exit(DoReadFile(Args))
      else if CleanName = 'read_file_preview' then
        Exit(DoReadFilePreview(Args))
      else if CleanName = 'write_file' then
        Exit(DoWriteFile(Args))
      else if CleanName = 'list_files' then
        Exit(DoListFiles(Args))
      else if CleanName = 'search_text' then
        Exit(DoSearchText(Args))
      else if CleanName = 'read_file_lines' then
        Exit(DoReadFileLines(Args))
      else if CleanName = 'edit_file' then
        Exit(DoEditFile(Args))
      else if CleanName = 'delete_file' then
        Exit(DoDeleteFile(Args))
      else if CleanName = 'move_file' then
        Exit(DoMoveFile(Args))
      else if CleanName = 'copy_file' then
        Exit(DoCopyFile(Args))
      else if CleanName = 'file_info' then
        Exit(DoFileInfo(Args))
      else if CleanName = 'create_directory' then
        Exit(DoCreateDirectory(Args))
      else if CleanName = 'find_files' then
        Exit(DoFindFiles(Args))
      else if CleanName = 'grep' then
        Exit(DoGrep(Args))
      else if CleanName = 'read_agents_md' then
        Exit(DoReadAgentsMd(Args));
    end;

    if (CleanName = 'exec_command') and (afExecCommand in FFeatures) then
    begin
      Result := '{"error": "no OnExecCommand handler"}';
      if not Assigned(FOnExecCommand) then
        Exit;
      Command := '';
      if Args <> nil then
        Command := Args.Get('command', '');
      Call := TExecCommandCall.Create;
      try
        Call.Agent := Self;
        Call.Command := Command;
        Call.Allow := True;
        Call.Result := '';
        TThread.Synchronize(nil, @Call.Invoke);
        Allow := Call.Allow;
        Res := Call.Result;
      finally
        Call.Free;
      end;
      if Allow then
        Result := Res
      else
        Result := '{"error": "denied by host"}';
      Exit;
    end;

    if afGit in FFeatures then
    begin
      if CleanName = 'git_status' then
        Exit(DoGitStatus(Args))
      else if CleanName = 'git_diff' then
        Exit(DoGitDiff(Args))
      else if CleanName = 'git_log' then
        Exit(DoGitLog(Args))
      else if CleanName = 'git_commit' then
        Exit(DoGitCommit(Args));
    end;

    if (CleanName = 'ask_user') and (afInteractive in FFeatures) then
      Exit(DoAskUser(Args));

    if afWebTools in FFeatures then
    begin
      if CleanName = 'web_fetch' then
        Exit(DoWebFetch(Args))
      else if CleanName = 'web_search' then
        Exit(DoWebSearch(Args));
    end;

    // finish is handled in Execute before DispatchTool is called
    Result := BuildUnknownToolError(CleanName);
  finally
    Args.Free;
  end;
end;

function TCustomOllamaAgent.BuildUnknownToolError(const AName: string): string;
var
  Available, Hint, BestName: string;
  LowName: string;
  Names: TStringList;
  I, Dist, BestDist: integer;

// Returns a replacement hint for known aliases from other agent frameworks
  function SuggestFor(const AName: string): string;
  begin
    if (AName = 'glob') or (AName = 'search_files') or (AName = 'find') then
      Exit('use find_files with a glob pattern like "*.pas" or "src/*.md"');
    if (AName = 'bash') or (AName = 'shell') or (AName = 'run') or (AName = 'execute') then
      Exit('use exec_command');
    if (AName = 'read') or (AName = 'view') or (AName = 'open') then
      Exit('use read_file or read_file_preview');
    if (AName = 'write') or (AName = 'create') or (AName = 'save') then
      Exit('use write_file');
    if (AName = 'edit') or (AName = 'replace') then
      Exit('use edit_file');
    if (AName = 'delete') or (AName = 'remove') or (AName = 'rm') then
      Exit('use delete_file');
    if (AName = 'ls') or (AName = 'dir') then
      Exit('use list_files');
    if (AName = 'search') or (AName = 'rg') or (AName = 'ripgrep') then
      Exit('use grep');
    Result := '';
  end;

begin
  Available := BuildToolsNames;
  if Available = '' then
    Available := 'none';
  LowName := LowerCase(AName);
  Hint := SuggestFor(LowName);
  BestName := '';

  // Fall back to fuzzy matching against the actual tool list
  if (Hint = '') and (Available <> 'none') then
  begin
    Names := TStringList.Create;
    try
      Names.CommaText := Available;
      // First check for hallucinated suffixes, read_file_xxx for read_file
      for I := 0 to Names.Count - 1 do
      begin
        if (Length(Names[I]) >= 4) and (Length(LowName) > Length(Names[I])) and
          (Copy(LowName, 1, Length(Names[I])) = LowerCase(Names[I])) then
        begin
          BestName := Names[I];
          Break;
        end;
      end;
      // Then fall back to small edit distance for typos
      if BestName = '' then
      begin
        BestDist := MaxInt;
        for I := 0 to Names.Count - 1 do
        begin
          Dist := LevenshteinDistance(LowName, LowerCase(Names[I]));
          if Dist < BestDist then
          begin
            BestDist := Dist;
            BestName := Names[I];
          end;
        end;
        if BestDist > 3 then
          BestName := '';
      end;
    finally
      Names.Free;
    end;
    if BestName <> '' then
      Hint := 'the tool is named "' + BestName + '", not "' + AName + '". ' +
        'Tool names must match exactly, do not append suffixes or variations. ' + 'Retry with name="' + BestName + '".';
  end;

  Result := '{"error": "unknown tool: ' + AName + '", ';
  if Hint <> '' then
    Result := Result + '"hint": ' + TJSONString.Create(Hint).AsJSON + ', ';
  Result := Result + '"available_tools": ' + TJSONString.Create(Available).AsJSON + '}';
end;

end.
