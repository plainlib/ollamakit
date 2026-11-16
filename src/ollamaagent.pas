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
  Classes, SysUtils, Controls, fpjson, jsonparser, OllamaManager, Network;

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
    // Shell executable that runs exec_command, empty falls back to platform default
    FExecShellInfo: string;
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
    // Resets usage counters in the manager and this agent
    procedure ResetUsage;

    property Done: boolean read FDone;
    property FinalAnswer: string read FFinalAnswer;
    // Context text placed before the next user message, cleared after the run
    property ContextPrelude: string read FContextPrelude write FContextPrelude;
    // Shell executable name for exec_command, injected into the system prompt
    property ExecShellInfo: string read FExecShellInfo write FExecShellInfo;
    property History: string read GetHistory write SetHistory;
    property ContextUsed: integer read FContextUsed;
    property ContextTotal: integer read FContextTotal;
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
  FileUtil, Math, RegExpr, Masks;

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

// Returns path relative to ARoot for display, or full path when outside root
function RelativeToRoot(const ARoot, APath: string): string;
begin
  if Pos(LowerCase(IncludeTrailingPathDelimiter(ARoot)), LowerCase(APath)) = 1 then
    Result := Copy(APath, Length(ARoot) + 2, MaxInt)
  else
    Result := APath;
end;

// Reads file as UTF-8 text, returns False on failure
function ReadTextFileSafe(const APath: string; out AContent: string): boolean;
var
  Stream: TFileStream;
  Buf: TBytes = ();
  ReadCount: int64;
begin
  Result := False;
  AContent := '';
  if not FileExists(APath) then
    Exit;
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Buf, Stream.Size);
    if Length(Buf) > 0 then
      ReadCount := Stream.Read(Buf[0], Length(Buf))
    else
      ReadCount := 0;
    SetLength(Buf, ReadCount);
    AContent := string(Buf);
    Result := True;
  finally
    Stream.Free;
  end;
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

// Returns True for localhost names and loopback addresses
function IsLocalhostHost(const AHost: string): boolean;
var
  H: string;
begin
  H := LowerCase(Trim(AHost));
  Result := (H = 'localhost') or (H = 'localhost.localdomain') or (H = '127.0.0.1') or (H = '0.0.0.0') or
    (H = '::1') or (Copy(H, 1, 4) = '127.');
end;

// Returns True for RFC1918 private and link-local IPv4 addresses
function IsPrivateIPv4(const AHost: string): boolean;
var
  Octet1, Octet2, P: integer;
  Rest: string;
begin
  Result := False;
  P := Pos('.', AHost);
  if P = 0 then
    Exit;
  Octet1 := StrToIntDef(Copy(AHost, 1, P - 1), -1);
  if Octet1 < 0 then
    Exit;
  Rest := Copy(AHost, P + 1, MaxInt);
  P := Pos('.', Rest);
  if P = 0 then
    Exit;
  Octet2 := StrToIntDef(Copy(Rest, 1, P - 1), -1);
  if Octet2 < 0 then
    Exit;
  if Octet1 = 10 then
    Exit(True);
  if (Octet1 = 172) and (Octet2 >= 16) and (Octet2 <= 31) then
    Exit(True);
  if (Octet1 = 192) and (Octet2 = 168) then
    Exit(True);
  if (Octet1 = 169) and (Octet2 = 254) then
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
  U := LowerCase(Trim(AUrl));
  if Copy(U, 1, 7) = 'http://' then
    U := Copy(U, 8, MaxInt)
  else if Copy(U, 1, 8) = 'https://' then
    U := Copy(U, 9, MaxInt)
  else
    Exit;
  P := 1;
  while (P <= Length(U)) and not (U[P] in ['/', '?', '#', ':']) do
    Inc(P);
  AHost := Copy(U, 1, P - 1);
  Result := AHost <> '';
end;

// Strips HTML tags, script and style blocks, decodes common entities
function StripHtmlTags(const AHtml: string): string;
var
  I, P: integer;
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
      P := PosFrom('>', AHtml, I);
      if P > 0 then
      begin
        I := P + 1;
        Continue;
      end;
    end;
    Result := Result + AHtml[I];
    Inc(I);
  end;
  // Collapse whitespace
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #9, ' ', [rfReplaceAll]);
  while Pos('  ', Result) > 0 do
    Result := StringReplace(Result, '  ', ' ', [rfReplaceAll]);
  // Decode common entities
  Result := StringReplace(Result, '&amp;', '&', [rfReplaceAll]);
  Result := StringReplace(Result, '&lt;', '<', [rfReplaceAll]);
  Result := StringReplace(Result, '&gt;', '>', [rfReplaceAll]);
  Result := StringReplace(Result, '&quot;', '"', [rfReplaceAll]);
  Result := StringReplace(Result, '&#39;', '''', [rfReplaceAll]);
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

procedure TRouteCall.Invoke;
begin
  // Caller frees the object after Synchronize returns
  if Assigned(Agent.FOnRoute) then
    Agent.FOnRoute(Agent, Op, Payload, Allow);
end;

procedure TChunkCall.Invoke;
begin
  try
    if Assigned(Agent.FOnChunk) then
      Agent.FOnChunk(Agent, Text);
  finally
    Free;
  end;
end;

procedure TThinkingCall.Invoke;
begin
  try
    if Assigned(Agent.FOnThinking) then
      Agent.FOnThinking(Agent, Text);
  finally
    Free;
  end;
end;

procedure TToolCallCall.Invoke;
begin
  try
    if Assigned(Agent.FOnToolCall) then
      Agent.FOnToolCall(Agent, Name, Args);
  finally
    Free;
  end;
end;

procedure TToolResultCall.Invoke;
begin
  try
    if Assigned(Agent.FOnToolResult) then
      Agent.FOnToolResult(Agent, Name, Result);
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
  // Caller frees the object after Synchronize returns
  Allow := True;
  if Assigned(Agent.FOnExecCommand) then
    Agent.FOnExecCommand(Agent, Command, Result, Allow);
end;

procedure TAskUserCall.Invoke;
begin
  // Caller frees the object after Synchronize returns
  Allow := True;
  Answer := '';
  if Assigned(Agent.FOnAskUser) then
    Agent.FOnAskUser(Agent, Question, Answer, Allow);
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
    begin
      WriteLn(ErrOutput, Text);
      Flush(ErrOutput);
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
var
  Step, I, SavedTimeout, EffectiveMaxSteps: integer;
  MessagesArr: TJSONArray;
  MessagesJson, ToolsJson, FinalJson, ErrMsg: string;
  Kind: TOllamaErrorKind;
  Allow: boolean;
  Reason: TAgentFinishReason;
  Data, MessageData, ToolCallsData, FuncData, ArgsData, FinishData: TJSONData;
  ToolCallsArr: TJSONArray;
  ToolCallObj, FuncObj, MsgObj: TJSONObject;
  ToolName, ToolArgs, ToolResult, FinalContent: string;
  Attempt, TruncIdx, TruncSeen, TruncTotalTool: integer;
  TruncContent: string;
  ResolvedCtx: int64;
  SystemPromptText: string;
begin
  Reason := afrError;
  ErrMsg := '';
  FinalContent := '';
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

      ToolsJson := FAgent.BuildToolsSchemaJson;
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
        FAgent.LogLine(Format('Step %d messages=%d timeout=%d', [Step, MessagesArr.Count, FAgent.OllamaManager.RequestTimeout]));

        // Temporarily override manager timeout when agent has its own
        SavedTimeout := FAgent.OllamaManager.RequestTimeout;
        if FAgent.FRequestTimeout > 0 then
          FAgent.OllamaManager.RequestTimeout := FAgent.FRequestTimeout;
        try
          // Retry the chat call on transport timeout when nothing was streamed yet
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
            if (Kind <> oekTimeout) or (FCurrentContent <> '') or (Attempt = CHAT_MAX_ATTEMPTS) then
              Break;
            FAgent.LogLine(Format('Chat timeout, retrying (attempt %d of %d)', [Attempt + 1, CHAT_MAX_ATTEMPTS]));
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
          // Add an actionable hint for the most common context error
          if Pos('context length', LowerCase(ErrMsg)) > 0 then
            ErrMsg := ErrMsg + LineEnding + 'hint: use "cls" to clear history, or "set numctx <larger>" to raise the window';
          FAgent.LogLine(Format('Abort: chat error kind=%d msg="%s"', [Ord(Kind), ErrMsg]));
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

          if (ToolCallsArr = nil) or (ToolCallsArr.Count = 0) then
          begin
            if (MessageData <> nil) and (MessageData.JSONType = jtObject) then
              FinalContent := TJSONObject(MessageData).Get('content', '');
            if FinalContent = '' then
              FinalContent := FCurrentContent;
            // Content is already emitted by ChatStream or ChatWithTools callbacks
            FAgent.LogLine(Format('Finished: content_len=%d tool_calls=0', [Length(FinalContent)]));
            Reason := afrSuccess;
            Exit;
          end;

          FAgent.LogLine(Format('ToolCalls count=%d', [ToolCallsArr.Count]));

          for I := 0 to ToolCallsArr.Count - 1 do
          begin
            if FAgent.FCancelled then
            begin
              Reason := afrCancelled;
              Exit;
            end;

            ToolCallObj := ToolCallsArr.Objects[I];
            if ToolCallObj = nil then
              Continue;

            FuncData := ToolCallObj.Find('function');
            if (FuncData = nil) or (FuncData.JSONType <> jtObject) then
              Continue;
            FuncObj := TJSONObject(FuncData);

            ToolName := FuncObj.Get('name', '');

            // Arguments can be a JSON object or a JSON string depending on server
            ArgsData := FuncObj.Find('arguments');
            if ArgsData = nil then
              ToolArgs := '{}'
            else if ArgsData.JSONType = jtString then
              ToolArgs := TJSONString(ArgsData).AsString
            else
              ToolArgs := ArgsData.AsJSON;

            QueueToolCall(ToolName, ToolArgs);

            QueueRoute(aoToolCall, ToolName + ' ' + ToolArgs, Allow);
            if Allow then
            begin
              // finish tool terminates the run immediately with the given message
              if (ToolName = 'finish') and (afFinish in FAgent.FFeatures) then
              begin
                FinishData := nil;
                try
                  try
                    FinishData := GetJSON(ToolArgs);
                    if (FinishData <> nil) and (FinishData.JSONType = jtObject) then
                      FinalContent := TJSONObject(FinishData).Get('message', '');
                  except
                    FinalContent := '';
                  end;
                finally
                  FinishData.Free;
                end;
                if FinalContent = '' then
                  FinalContent := FCurrentContent;
                FAgent.LogLine('Finished: explicit finish tool called');
                Reason := afrSuccess;
                Exit;
              end;
              ToolResult := FAgent.DispatchTool(ToolName, ToolArgs);
            end
            else
              ToolResult := '{"error": "denied by host"}';

            QueueToolResult(ToolName, ToolResult);

            MsgObj := TJSONObject.Create;
            MsgObj.Add('role', 'tool');
            MsgObj.Add('content', ToolResult);
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
        // Close the cancelled turn so the next user message does not
        // appear as two user messages in a row and lose the current request
        if Reason = afrCancelled then
        begin
          // Resolve orphaned tool calls that were never executed
          if (MessagesArr.Count > 0) and (MessagesArr.Items[MessagesArr.Count - 1].JSONType = jtObject) then
          begin
            Data := TJSONObject(MessagesArr.Items[MessagesArr.Count - 1]).Find('tool_calls');
            if (Data <> nil) and (Data.JSONType = jtArray) then
            begin
              for I := 0 to TJSONArray(Data).Count - 1 do
              begin
                MsgObj := TJSONObject.Create;
                MsgObj.Add('role', 'tool');
                MsgObj.Add('content', '{"error": "cancelled by user before execution"}');
                MessagesArr.Add(MsgObj);
              end;
            end;
            // Do not free Data, it is owned by the parent message object
            Data := nil;
          end;
          // Close the turn with partial content and a cancel marker
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
var
  ToolList, PlatformName, EnvironmentBlock, ShellDesc: string;
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

  // One universal rule: file tools take relative paths, not absolute
  EnvironmentBlock := EnvironmentBlock + '- File tool paths are relative to the workspace root, never absolute paths.' + LineEnding;

  Result := Result + #10#10 + EnvironmentBlock;

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
  if Normalized = '' then
    Exit(Root);
  // Absolute paths are resolved as-is, not prefixed with Root
  if IsPathAbsolute(Normalized) then
    Full := ExpandFileName(Normalized)
  else
    Full := ExpandFileName(Root + Normalized);
  // Compare with trailing delimiter so '.' resolves to root itself
  if Pos(LowerCase(Root), LowerCase(IncludeTrailingPathDelimiter(Full))) = 1 then
    Result := Full;
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
      AddTool(Arr, 'read_file',
        'Read contents of a file inside the workspace. By default reads up to 50000 bytes. ' +
        'Set max_bytes to a larger number to read more, or 0 to read the whole file. ' +
        'WARNING: only use max_bytes=0 (whole file) as a last resort and only when the file ' +
        'is known to be small, otherwise prefer read_file_preview or read_file_lines.',
        '{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"},"max_bytes":{"type":"integer","description":"Maximum bytes to read, default 50000, set 0 to read the whole file (use only for small files)"}},"required":["path"]}');
      AddTool(Arr, 'read_file_preview',
        'Show a quick preview of a text file: first N lines, last N lines and total size. ' +
        'Language-agnostic, works for source code, markdown, configs, logs. ' +
        'Use this FIRST when exploring an unknown file or a file larger than 50 KB, ' +
        'before deciding whether to read the whole file with read_file or specific ranges ' + 'with read_file_lines.',
        '{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"},"head":{"type":"integer","description":"Number of first lines to show, default 30, max 500"},"tail":{"type":"integer","description":"Number of last lines to show, default 30, max 500"}},"required":["path"]}');
      AddTool(Arr, 'write_file', 'Write contents to a file inside the workspace, creates parent directories',
        '{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}');
      AddTool(Arr, 'list_files', 'List files in a directory inside the workspace, non-recursive',
        '{"type":"object","properties":{"path":{"type":"string","description":"Optional relative directory"}}}');
      AddTool(Arr, 'search_text', 'Search for a literal text pattern in files, returns file and line',
        '{"type":"object","properties":{"path":{"type":"string"},"pattern":{"type":"string"},"recursive":{"type":"boolean"}},"required":["pattern"]}');
      AddTool(Arr, 'read_file_lines',
        'Read a specific line range from a file. Use this instead of read_file when the file ' +
        'is larger than 50 KB or when read_file returned a truncation notice. Each call reads ' +
        'up to 5000 lines. To read a whole large file, call repeatedly with increasing start_line. ' +
        'Example: path="src/mainform.pas", start_line=1, end_line=500 for the first 500 lines.',
        '{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":"integer","description":"First line to read, 1-based"},"end_line":{"type":"integer","description":"Last line to read, inclusive"}},"required":["path"]}');
      AddTool(Arr, 'edit_file',
        'Replace an exact string in a file. By default the old string must occur exactly once, set replace_all=true to replace all occurrences',
        '{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["path","old_string","new_string"]}');
      AddTool(Arr, 'delete_file', 'Delete a file inside the workspace',
        '{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}');
      AddTool(Arr, 'move_file', 'Move or rename a file inside the workspace',
        '{"type":"object","properties":{"source":{"type":"string"},"destination":{"type":"string"}},"required":["source","destination"]}');
      AddTool(Arr, 'copy_file', 'Copy a file inside the workspace',
        '{"type":"object","properties":{"source":{"type":"string"},"destination":{"type":"string"}},"required":["source","destination"]}');
      AddTool(Arr, 'file_info', 'Get size, modification time and type of a file or directory',
        '{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}');
      AddTool(Arr, 'create_directory', 'Create a directory and all parent directories',
        '{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}');
      AddTool(Arr, 'find_files',
        'Find files by name using shell wildcards: * matches any characters, ? matches one character. ' +
        'Examples: "*.md" finds all markdown files, "src/*.pas" finds pascal files in src, ' +
        '"config.*" finds config with any extension. Search is recursive by default, do NOT ' +
        'add a ** prefix. Character classes like [abc] are not supported. Capped at 2000 results.',
        '{"type":"object","properties":{"path":{"type":"string"},"pattern":{"type":"string"},"recursive":{"type":"boolean"}},"required":["pattern"]}');
      AddTool(Arr, 'grep',
        'Search text in files using a regex or literal pattern, capped at 500 matches. ' +
        'path can be a single file (searches only that file, like Unix grep file.txt) ' +
        'or a directory (searches all files in it recursively). ' +
        'When scanning a directory, up to 2000 files are checked and common junk ' +
        'directories like .git, node_modules, bin, obj are skipped automatically. ' +
        'If scan_limited is true in the response, narrow the path and try again. ' +
        'Returns JSON with file, line and text for each match.',
        '{"type":"object","properties":{"path":{"type":"string","description":"File or directory to search, default is workspace root"},"pattern":{"type":"string"},"recursive":{"type":"boolean","description":"Recurse into subdirectories when path is a directory, default true"},"literal":{"type":"boolean","description":"Literal substring match, default true, set false for regex"}},"required":["pattern"]}');
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
      AddTool(Arr, 'finish', 'Declare the task complete and return a final message to the user',
        '{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}');

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
      Names.Add('read_file');
      Names.Add('read_file_preview');
      Names.Add('write_file');
      Names.Add('list_files');
      Names.Add('search_text');
      Names.Add('read_file_lines');
      Names.Add('edit_file');
      Names.Add('delete_file');
      Names.Add('move_file');
      Names.Add('copy_file');
      Names.Add('file_info');
      Names.Add('create_directory');
      Names.Add('find_files');
      Names.Add('grep');
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

function TCustomOllamaAgent.DoReadFile(AArgs: TJSONObject): string;
const
  DEFAULT_MAX_BYTES = 50000;
  // Hard cap for max_bytes=0 to protect memory on accidental huge files
  HARD_LIMIT_BYTES = 16 * 1024 * 1024;
var
  RelPath, FullPath, Content: string;
  Stream: TFileStream;
  Buf: TBytes = ();
  ReadCount: int64;
  FullSize: int64;
  MaxBytes: int64;
  I, LinesShown: integer;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
    Exit;
  end;
  if not FileExists(FullPath) then
  begin
    Result := '{"error": "file not found"}';
    Exit;
  end;
  MaxBytes := AArgs.Get('max_bytes', DEFAULT_MAX_BYTES);
  // Negative values fall back to default, 0 means whole file up to the hard cap
  if MaxBytes < 0 then
    MaxBytes := DEFAULT_MAX_BYTES;
  if (MaxBytes = 0) or (MaxBytes > HARD_LIMIT_BYTES) then
    MaxBytes := HARD_LIMIT_BYTES;
  Stream := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyNone);
  try
    FullSize := Stream.Size;
    SetLength(Buf, Min(FullSize, MaxBytes));
    if Length(Buf) > 0 then
      ReadCount := Stream.Read(Buf[0], Length(Buf))
    else
      ReadCount := 0;
    SetLength(Buf, ReadCount);
    Content := string(Buf);
  finally
    Stream.Free;
  end;
  // Tell the model how much was shown and where to continue
  if FullSize > ReadCount then
  begin
    LinesShown := 0;
    for I := 1 to Length(Content) do
      if Content[I] = #10 then
        Inc(LinesShown);
    Content := Content + #10#10 + '[file truncated: showed ' + IntToStr(ReadCount) + ' of ' + IntToStr(FullSize) +
      ' bytes (' + IntToStr(LinesShown) + ' lines). ' + 'Use read_file_lines with start_line=' +
      IntToStr(LinesShown + 1) + ' to continue reading from where this message left off, ' +
      'or call read_file again with a larger max_bytes value if the file is small]';
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
  Size: int64;
  Buf: TStringBuilder;
  Stream: TFileStream;
  RawBuf: TBytes = ();
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
    Exit;
  end;
  if not FileExists(FullPath) then
  begin
    Result := '{"error": "file not found"}';
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
  // Detect binary files by scanning the first 512 bytes for null bytes
  HeadCount := 0;
  try
    Stream := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(RawBuf, Min(Size, 512));
      if Length(RawBuf) > 0 then
        HeadCount := Stream.Read(RawBuf[0], Length(RawBuf));
    finally
      Stream.Free;
    end;
  except
    HeadCount := 0;
  end;
  for I := 0 to HeadCount - 1 do
    if RawBuf[I] = 0 then
    begin
      Result := '{"error": "binary file detected (null bytes found), use exec_command for this file type"}';
      Exit;
    end;
  HeadCount := AArgs.Get('head', DEFAULT_HEAD);
  TailCount := AArgs.Get('tail', DEFAULT_TAIL);
  if HeadCount < 1 then
    HeadCount := DEFAULT_HEAD;
  if HeadCount > MAX_LINES_PER_EDGE then
    HeadCount := MAX_LINES_PER_EDGE;
  if TailCount < 0 then
    TailCount := DEFAULT_TAIL;
  if TailCount > MAX_LINES_PER_EDGE then
    TailCount := MAX_LINES_PER_EDGE;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(FullPath);
    except
      Result := '{"error": "cannot read file"}';
      Exit;
    end;
    TotalLines := Lines.Count;
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
      Buf.Append('To read a specific range use read_file_lines with start_line and end_line. ');
      Buf.Append('To read the first 50 KB use read_file.');
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
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
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
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
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
      Result := Arr.AsJSON;
    finally
      Arr.Free;
    end;
  finally
    Items.Free;
  end;
end;

function TCustomOllamaAgent.DoSearchText(AArgs: TJSONObject): string;
var
  RelPath, FullPath, Pattern: string;
  Recursive: boolean;
  Files: TStringList;
  Matches: TJSONArray;
  FileLines: TStringList;
  I, J: integer;
  Line: string;
  MatchObj: TJSONObject;
  BaseRoot: string;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  Pattern := AArgs.Get('pattern', '');
  Recursive := AArgs.Get('recursive', True);
  if Pattern = '' then
  begin
    Result := '{"error": "pattern required"}';
    Exit;
  end;
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
    Exit;
  end;
  if not DirectoryExists(FullPath) then
  begin
    Result := '{"error": "directory not found"}';
    Exit;
  end;

  BaseRoot := IncludeTrailingPathDelimiter(GetEffectiveRootPath);
  Files := TStringList.Create;
  Matches := TJSONArray.Create;
  try
    FindAllFiles(Files, FullPath, '*.*', Recursive);
    for I := 0 to Files.Count - 1 do
    begin
      FileLines := TStringList.Create;
      try
        try
          FileLines.LoadFromFile(Files[I]);
        except
          Continue;
        end;
        for J := 0 to FileLines.Count - 1 do
        begin
          Line := FileLines[J];
          if Pos(Pattern, Line) > 0 then
          begin
            MatchObj := TJSONObject.Create;
            MatchObj.Add('file', Copy(Files[I], Length(BaseRoot) + 1, MaxInt));
            MatchObj.Add('line', J + 1);
            MatchObj.Add('text', Line);
            Matches.Add(MatchObj);
          end;
        end;
      finally
        FileLines.Free;
      end;
    end;
    Result := Matches.AsJSON;
  finally
    Matches.Free;
    Files.Free;
  end;
end;

function TCustomOllamaAgent.DoReadFileLines(AArgs: TJSONObject): string;
var
  RelPath, FullPath: string;
  Lines: TStringList;
  StartLine, EndLine, I: integer;
  Buf: TStringBuilder;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
    Exit;
  end;
  if not FileExists(FullPath) then
  begin
    Result := '{"error": "file not found"}';
    Exit;
  end;
  StartLine := AArgs.Get('start_line', 1);
  EndLine := AArgs.Get('end_line', -1);
  if StartLine < 1 then
    StartLine := 1;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(FullPath);
    except
      Result := '{"error": "cannot read file"}';
      Exit;
    end;
    if EndLine < 0 then
      EndLine := Lines.Count
    else if EndLine > Lines.Count then
      EndLine := Lines.Count;
    // Cap at 5000 lines per call
    if EndLine - StartLine + 1 > 5000 then
      EndLine := StartLine + 4999;
    Buf := TStringBuilder.Create;
    try
      for I := StartLine - 1 to EndLine - 1 do
      begin
        Buf.Append(Lines[I]);
        if I < EndLine - 1 then
          Buf.Append(LineEnding);
      end;
      Result := '{"content": ' + TJSONString.Create(Buf.ToString).AsJSON + ', "total_lines": ' +
        IntToStr(Lines.Count) + ', "shown_from": ' + IntToStr(StartLine) + ', "shown_to": ' + IntToStr(EndLine) + '}';
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
  OldStr := AArgs.Get('old_string', '');
  NewStr := AArgs.Get('new_string', '');
  ReplaceAll := AArgs.Get('replace_all', False);
  if OldStr = '' then
  begin
    Result := '{"error": "old_string is required"}';
    Exit;
  end;
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
    Exit;
  end;
  if not FileExists(FullPath) then
  begin
    Result := '{"error": "file not found"}';
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
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
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
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
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
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
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
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
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
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
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
var
  RelPath, FullPath, Pattern: string;
  Recursive: boolean;
  Files: TStringList;
  Arr: TJSONArray;
  I: integer;
  BaseRoot: string;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  Pattern := AArgs.Get('pattern', '*');
  Recursive := AArgs.Get('recursive', True);
  if Pattern = '' then
    Pattern := '*';
  // Accept git-style globs and character classes from the model
  Pattern := NormalizeGlobPattern(Pattern);
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
    Exit;
  end;
  if not DirectoryExists(FullPath) then
  begin
    Result := '{"error": "directory not found"}';
    Exit;
  end;
  BaseRoot := IncludeTrailingPathDelimiter(GetEffectiveRootPath);
  Files := TStringList.Create;
  Arr := TJSONArray.Create;
  try
    FindAllFiles(Files, FullPath, Pattern, Recursive);
    Files.Sort;
    for I := 0 to Files.Count - 1 do
    begin
      if Arr.Count >= MAX_RESULTS then
        Break;
      Arr.Add(RelativeToRoot(BaseRoot, Files[I]));
    end;
    Result := '{"count": ' + IntToStr(Arr.Count) + ', "truncated": ' + BoolToStr(Files.Count > MAX_RESULTS, 'true', 'false') +
      ', "files": ' + Arr.AsJSON + '}';
  finally
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
var
  RelPath, FullPath, Pattern: string;
  Recursive, Literal, SingleFile, ScanLimited: boolean;
  Files: TStringList;
  Matches: TJSONArray;
  I, FilesScanned: integer;
  BaseRoot: string;
  Regex: TRegExpr;
  GitPatterns: TStringList;
  StartTick: QWord;
  TimedOut: boolean;

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
    Lines := TStringList.Create;
    try
      try
        Lines.LoadFromFile(AFullPath);
      except
        Exit;
      end;
      for J := 0 to Lines.Count - 1 do
      begin
        if Matches.Count >= MAX_MATCHES then
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
          MatchObj := TJSONObject.Create;
          MatchObj.Add('file', ARelPath);
          MatchObj.Add('line', J + 1);
          MatchObj.Add('text', Line);
          Matches.Add(MatchObj);
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
  if Pattern = '' then
  begin
    Result := '{"error": "pattern required"}';
    Exit;
  end;
  RelPath := AArgs.Get('path', '');
  Recursive := AArgs.Get('recursive', True);
  Literal := AArgs.Get('literal', True);
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
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
    // Compile once, reuse for every line
    Regex := TRegExpr.Create;
    Regex.Expression := Pattern;
  end;
  Files := TStringList.Create;
  Matches := TJSONArray.Create;
  GitPatterns := LoadGitignorePatterns(GetEffectiveRootPath);
  ScanLimited := False;
  FilesScanned := 0;
  TimedOut := False;
  StartTick := GetTickCount64;
  try
    // A path to a file searches only that file, like Unix grep file.txt
    SingleFile := FileExists(FullPath) and not DirectoryExists(FullPath);
    if SingleFile then
    begin
      ScanFile(FullPath, RelativeToRoot(BaseRoot, FullPath));
    end
    else
    begin
      FindAllFiles(Files, FullPath, '*.*', Recursive);
      for I := 0 to Files.Count - 1 do
      begin
        if Matches.Count >= MAX_MATCHES then
          Break;
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
        Inc(FilesScanned);
        ScanFile(Files[I], RelPath);
      end;
      if (not TimedOut) and (FilesScanned >= MAX_FILES_SCANNED) then
        ScanLimited := True;
    end;
    Result := '{"count": ' + IntToStr(Matches.Count) + ', "truncated": ' + BoolToStr(Matches.Count >= MAX_MATCHES, 'true', 'false') +
      ', "scanned_files": ' + IntToStr(FilesScanned) + ', "scan_limited": ' + BoolToStr(ScanLimited, 'true', 'false') +
      ', "timed_out": ' + BoolToStr(TimedOut, 'true', 'false') + ', "matches": ' + Matches.AsJSON + '}';
  finally
    Matches.Free;
    Files.Free;
    GitPatterns.Free;
    if Regex <> nil then
      Regex.Free;
  end;
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
  Limit := 20;
  if AArgs <> nil then
    Limit := AArgs.Get('limit', 20);
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
  Url, Host, Content, ErrorMsg: string;
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
  if not IsSafeHttpUrl(Url, Host) then
  begin
    Result := '{"error": "only http and https urls are allowed"}';
    Exit;
  end;
  // Whitelist takes priority when configured
  if FWebOptions.AllowedHosts.Count > 0 then
  begin
    if FWebOptions.AllowedHosts.IndexOf(Host) < 0 then
    begin
      Result := '{"error": "host not in allowed list: ' + Host + '"}';
      Exit;
    end;
  end;
  if FWebOptions.BlockLocalhost and IsLocalhostHost(Host) then
  begin
    Result := '{"error": "localhost access is blocked"}';
    Exit;
  end;
  if FWebOptions.BlockPrivateIPs and IsPrivateIPv4(Host) then
  begin
    Result := '{"error": "private ip access is blocked"}';
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
  I: integer;
  Args: TJSONObject;
  Call: TExecCommandCall;
  Command, Res: string;
  Allow: boolean;
begin
  LogLine(Format('DispatchTool name="%s" args="%s"', [AName, Copy(AArgsJson, 1, 200)]));

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
      if FTools[I].Name = AName then
      begin
        Result := '';
        if Assigned(FTools[I].FOnExecute) then
          FTools[I].FOnExecute(Self, AArgsJson, Result);
        Exit;
      end;
    end;

    if afFileTools in FFeatures then
    begin
      if AName = 'read_file' then
        Exit(DoReadFile(Args))
      else if AName = 'read_file_preview' then
        Exit(DoReadFilePreview(Args))
      else if AName = 'write_file' then
        Exit(DoWriteFile(Args))
      else if AName = 'list_files' then
        Exit(DoListFiles(Args))
      else if AName = 'search_text' then
        Exit(DoSearchText(Args))
      else if AName = 'read_file_lines' then
        Exit(DoReadFileLines(Args))
      else if AName = 'edit_file' then
        Exit(DoEditFile(Args))
      else if AName = 'delete_file' then
        Exit(DoDeleteFile(Args))
      else if AName = 'move_file' then
        Exit(DoMoveFile(Args))
      else if AName = 'copy_file' then
        Exit(DoCopyFile(Args))
      else if AName = 'file_info' then
        Exit(DoFileInfo(Args))
      else if AName = 'create_directory' then
        Exit(DoCreateDirectory(Args))
      else if AName = 'find_files' then
        Exit(DoFindFiles(Args))
      else if AName = 'grep' then
        Exit(DoGrep(Args));
    end;

    if (AName = 'exec_command') and (afExecCommand in FFeatures) then
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
      if AName = 'git_status' then
        Exit(DoGitStatus(Args))
      else if AName = 'git_diff' then
        Exit(DoGitDiff(Args))
      else if AName = 'git_log' then
        Exit(DoGitLog(Args))
      else if AName = 'git_commit' then
        Exit(DoGitCommit(Args));
    end;

    if (AName = 'ask_user') and (afInteractive in FFeatures) then
      Exit(DoAskUser(Args));

    if afWebTools in FFeatures then
    begin
      if AName = 'web_fetch' then
        Exit(DoWebFetch(Args))
      else if AName = 'web_search' then
        Exit(DoWebSearch(Args));
    end;

    // finish is handled in Execute before DispatchTool is called
    Result := '{"error": "unknown tool: ' + AName + '"}';
  finally
    Args.Free;
  end;
end;

end.
