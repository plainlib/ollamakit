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
  OllamaAgent, AgentConfig{$IFDEF WINDOWS}, Windows{$ENDIF};

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
    FPrevAgentOnThinking: TAgentThinkingEvent;
    FPrevAgentOnToolCall: TAgentToolCallEvent;
    FPrevAgentOnToolResult: TAgentToolResultEvent;
    FPrevAgentOnFinish: TAgentFinishEvent;
    FPrevAgentOnExecCommand: TAgentExecCommandEvent;
    FPrevAgentOnAskUser: TAgentAskUserEvent;
    // True while writing agent thinking before the first content chunk
    FInThinking: boolean;
    FOnRoute: TTermRouteEvent;
    FOnOutput: TTermOutputEvent;
    FOnAgentExecute: TTermAgentEvent;
    FOnExit: TTermExitEvent;
    procedure SetPath(const AValue: string);
    procedure SetAgent(const AValue: TCustomOllamaAgent);
    procedure SetHistory(const AValue: TStringList);
    procedure SetColors(const AValue: TTermColorScheme);
    // Handles help, help agent, and ? alias
    procedure HandleHelpCommand(const AArg: string);
    // Handles set <name> <value>
    procedure HandleSetCommand(const AArg: string);
    // Handles get <name>
    procedure HandleGetCommand(const AArg: string);
    // Handles models, queries OllamaManager for available models
    procedure HandleModelsCommand(const AArg: string);
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
    procedure PumpOutput(const AData: rawbytestring; AIsStderr: boolean); virtual;
    // Redirects agent streamed chunks to console output
    procedure HandleAgentChunk(Sender: TObject; const AText: string);
    // Closes the active thinking block with a trailing blank line
    procedure CloseThinking;
    // Redirects agent thinking chunks to console output with a label
    procedure HandleAgentThinking(Sender: TObject; const AText: string);
    // Prints tool call label with surrounding blank lines
    procedure HandleAgentToolCall(Sender: TObject; const AName, AArgsJson: string);
    // Forwards tool result to host handler without console output
    procedure HandleAgentToolResult(Sender: TObject; const AName, AResult: string);
    // Finalizes console line after agent run
    procedure HandleAgentFinish(Sender: TObject; AReason: TAgentFinishReason; const AAnswer, AErrorMsg: string);
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
    property BuiltinCommands: TStringList read FBuiltinCommands;
    property HistoryMax: integer read FHistoryMax write FHistoryMax default 200;
    property ShellExec: string read FShellExec write FShellExec;
    property CommandTimeout: integer read FCommandTimeout write FCommandTimeout default 0;
    property MaxCaptureBytes: integer read FMaxCaptureBytes write FMaxCaptureBytes default 65536;
    property AgentCommandTimeout: integer read FAgentCommandTimeout write FAgentCommandTimeout default 30000;
    property UsePrefixes: boolean read FUsePrefixes write FUsePrefixes default True;
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
  while (Result > 0) and ((byte(S[Result]) and $C0) = $80) do
    Dec(Result);
  if (Result > 0) and (byte(S[Result]) >= $C0) then
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
  FHistory := TStringList.Create;
  FHistoryMax := 200;
  FShellExec := 'cmd.exe';
  FCommandTimeout := 0;
  FMaxCaptureBytes := 65536;
  FAgentCommandTimeout := 30000;
  FUsePrefixes := True;
  FSearchPath := True;
  FRunning := False;
  FLastExitCode := 0;
end;

destructor TCustomTermManager.Destroy;
begin
  SetAgent(nil);
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
    // Keep agent workspace in sync with terminal directory
    if Assigned(FAgent) and not (csDesigning in ComponentState) then
      FAgent.RootPath := GetEffectivePath;
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
  FInThinking := False;
  if Assigned(FAgent) then
  begin
    FAgent.FreeNotification(Self);
    // Share terminal directory with agent file tools at runtime only
    if not (csDesigning in ComponentState) and (FAgent.RootPath = '') then
      FAgent.RootPath := GetEffectivePath;
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

procedure TCustomTermManager.HandleAgentChunk(Sender: TObject; const AText: string);
begin
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
  // Emit label and newline once at the beginning of a thinking block
  if not FInThinking then
  begin
    SetColor(tcThinkingBadge);
    WriteLine(FThinkingLabel, True);
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
  WriteLine(LabelText, True);
  SetColor(tcDefault);
  // Blank line after tool call for visual separation
  WriteLine('', True);
  if Assigned(FPrevAgentOnToolCall) then
    FPrevAgentOnToolCall(Sender, AName, AArgsJson);
end;

procedure TCustomTermManager.HandleAgentToolResult(Sender: TObject; const AName, AResult: string);
begin
  // Tool result is forwarded to the model, no console output here
  if Assigned(FPrevAgentOnToolResult) then
    FPrevAgentOnToolResult(Sender, AName, AResult);
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
        WriteLine('[empty response from model]', True);
        SetColor(tcDefault);
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
      WriteLine('[max steps reached]', True);
      SetColor(tcDefault);
    end;
    afrError:
    begin
      SetColor(tcErrorBadge);
      WriteLine('[error: ' + AErrorMsg + ']', True);
      SetColor(tcDefault);
    end;
    afrModelNotSet:
    begin
      SetColor(tcErrorBadge);
      WriteLine('[agent not configured: ' + AErrorMsg + ']', True);
      SetColor(tcDefault);
    end;
    else
      ;
  end;
  // Blank line after any finish for visual separation from the next prompt
  WriteLine('', False);
  if Assigned(FPrevAgentOnFinish) then
    FPrevAgentOnFinish(Sender, AReason, AAnswer, AErrorMsg);
end;

procedure TCustomTermManager.HandleAgentExecCommand(Sender: TObject; const ACommand: string; var AResult: string; var AAllow: boolean);
var
  ExitCode: integer;
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
  if FStripEmoji then
    Sanitized := StripEmojiChars(AText)
  else
    Sanitized := AText;
  Utf8 := UTF8Encode(Sanitized);
  {$IFDEF WINDOWS}
  if AIsStderr then
    WriteUtf8ToHandle(GetStdHandle(STD_ERROR_HANDLE), Utf8)
  else
    WriteUtf8ToHandle(GetStdHandle(STD_OUTPUT_HANDLE), Utf8);
  {$ELSE}
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
  {$ENDIF}
  FLastCharWasNewLine := AText[Length(AText)] in [#10, #13];
  if Assigned(FOnOutput) then
    FOnOutput(Self, AText, AIsStderr);
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
    CtxKb := CtxUsedKb + '/' + CtxTotalKb + 'KB';
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
    // Clear agent conversation history and usage counters together with the screen
    if Assigned(FAgent) then
    begin
      FAgent.ClearHistory;
      FAgent.ResetUsage;
    end;
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
    DoOutput(FormatAgentConfig(FAgent) + LineEnding, False)
  else if Cmd = 'models' then
    HandleModelsCommand(Arg)
  else
    DoOutput('Unknown builtin: ' + Cmd + LineEnding, True);
end;

procedure TCustomTermManager.HandleHelpCommand(const AArg: string);
var
  Topic, CommandsList: string;
  BaseUrl, ModelName, MaxSteps, Streaming, Tools: string;

// Adds a labeled line with aligned description
  procedure Line(const ALabel, AValue, ADesc: string);
  var
    Pad: string;
  begin
    Pad := '  ' + ALabel;
    while Length(Pad) < 38 do
      Pad := Pad + ' ';
    DoOutput(Pad + AValue + '  (' + ADesc + ')' + LineEnding, False);
  end;

  // Returns comma separated short tool names for display in help
  function BuildToolsList(AFeatures: TAgentFeatures): string;
  var
    Parts: TStringList;
    F: TAgentFeature;
  begin
    Parts := TStringList.Create;
    try
      for F := Low(TAgentFeature) to High(TAgentFeature) do
        if F in AFeatures then
          Parts.Add(LowerCase(Copy(GetEnumName(TypeInfo(TAgentFeature), Ord(F)), 3, MaxInt)));
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
  else
  begin
    // Add a space after commas for readability
    CommandsList := StringReplace(FBuiltinCommands.CommaText, ',', ', ', [rfReplaceAll]);
    DoOutput('Built-in commands: ' + CommandsList + LineEnding, False);
    DoOutput('' + LineEnding, False);
    if Assigned(FAgent) then
    begin
      DoOutput('Current agent state:' + LineEnding, False);
      if Assigned(FAgent.OllamaManager) then
      begin
        BaseUrl := FAgent.OllamaManager.BaseURL;
        if BaseUrl = '' then
          BaseUrl := '(empty)';
      end
      else
        BaseUrl := '(no OllamaManager)';
      ModelName := FAgent.ModelName;
      if ModelName = '' then
        ModelName := '(not selected)';
      MaxSteps := IntToStr(FAgent.MaxSteps);
      if FAgent.MaxSteps = 0 then
        MaxSteps := '0 (unlimited)';
      if FAgent.Streaming then
        Streaming := 'on'
      else
        Streaming := 'off';
      Tools := BuildToolsList(FAgent.EnabledTools);
      Line('baseurl', BaseUrl, 'set baseurl <url> to change');
      Line('model', ModelName, 'set model <name>, or "models" to list');
      Line('maxsteps', MaxSteps, 'set maxsteps <n>, 0 for unlimited');
      Line('streaming', Streaming, 'set streaming on|off');
      Line('tools', Tools, 'set tools <list>, "set tools all" or "none"');
    end
    else
    begin
      DoOutput('No agent attached, showing examples:' + LineEnding, False);
      Line('baseurl', 'http://localhost:11434', 'Set Ollama server URL');
      Line('model', 'qwen2.5:7b', 'Select a model for the agent');
      Line('maxsteps', '20', 'Iteration limit, 0 for unlimited');
      Line('streaming', 'on', 'Real time output');
      Line('tools', 'filetools, exec, web', 'Enabled tool groups');
    end;
    DoOutput('' + LineEnding, False);
    DoOutput('Other commands: config (all settings), models (installed models), get/set <name>' + LineEnding, False);
    DoOutput('Full property reference: help agent, or just "?"' + LineEnding, False);
    DoOutput('' + LineEnding, False);
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
    DoOutput('use "help agent" for list of properties' + LineEnding, True);
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
  if SetAgentProperty(FAgent, PropName, PropValue, ErrMsg) then
    DoOutput(PropName + ' = ' + PropValue + LineEnding, False)
  else
    DoOutput('error: ' + ErrMsg + LineEnding, True);
end;

procedure TCustomTermManager.HandleGetCommand(const AArg: string);
const
  MAX_PREVIEW = 500;
var
  Value, ErrMsg, Display, Tail: string;
begin
  if Trim(AArg) = '' then
  begin
    DoOutput('usage: get <name>' + LineEnding, True);
    DoOutput('use "help agent" for list of properties' + LineEnding, True);
    Exit;
  end;
  if not GetAgentProperty(FAgent, Trim(AArg), Value, ErrMsg) then
  begin
    DoOutput('error: ' + ErrMsg + LineEnding, True);
    Exit;
  end;
  // Collapse newlines and truncate long values for display
  Display := StringReplace(Value, #13#10, ' ', [rfReplaceAll]);
  Display := StringReplace(Display, #10, ' ', [rfReplaceAll]);
  Display := StringReplace(Display, #13, ' ', [rfReplaceAll]);
  Tail := '';
  if Length(Display) > MAX_PREVIEW then
  begin
    Display := Copy(Display, 1, MAX_PREVIEW);
    Tail := ' ... [' + IntToStr(Length(Value)) + ' chars total, truncated]';
  end;
  DoOutput(AArg + ' = ' + Display + Tail + LineEnding, False);
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

procedure TCustomTermManager.PumpOutput(const AData: rawbytestring; AIsStderr: boolean);
var
  Tmp: rawbytestring;
begin
  if Length(AData) = 0 then
    Exit;
  // Bytes from cmd.exe are in OEM code page, convert bytes explicitly to UTF-8
  Tmp := AData;
  SetCodePage(Tmp, GetOEMCP, False);
  SetCodePage(Tmp, CP_UTF8, True);
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
begin
  Result := -1;
  Buffer := Default(TTermBuffer);
  if ACommand = '' then
    Exit;
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
  RawData := '';
  Process := TProcess.Create(nil);
  try
    Process.Executable := FShellExec;
    {$IFDEF WINDOWS}
    Process.Parameters.Add('/c');
    {$ELSE}
    Process.Parameters.Add('-c');
    {$ENDIF}
    Process.Parameters.Add(ACommand);
    Process.Options := [poUsePipes, poNoConsole];
    Process.CurrentDirectory := GetEffectivePath;
    Process.Execute;
    StartTime := Now;

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

    Result := Process.ExitStatus;
  finally
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
    {$ELSE}
    Process.Parameters.Add('-c');
    {$ENDIF}
    Process.Parameters.Add(ACommand);
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

    // Convert OEM bytes from shell to UTF-8
    Tmp := Captured;
    SetCodePage(Tmp, GetOEMCP, False);
    SetCodePage(Tmp, CP_UTF8, True);
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
        tikBuiltin: HandleBuiltin(Payload);
        tikCommand: FLastExitCode := ExecuteCommand(Payload);
        tikAgent:
          if Assigned(FAgent) then
          begin
            // Save user handlers, install our own for the duration of the run
            FPrevAgentOnChunk := FAgent.OnChunk;
            FPrevAgentOnThinking := FAgent.OnThinking;
            FPrevAgentOnToolCall := FAgent.OnToolCall;
            FPrevAgentOnToolResult := FAgent.OnToolResult;
            FPrevAgentOnFinish := FAgent.OnFinish;
            FPrevAgentOnExecCommand := FAgent.OnExecCommand;
            FPrevAgentOnAskUser := FAgent.OnAskUser;
            FAgent.OnChunk := @HandleAgentChunk;
            FAgent.OnThinking := @HandleAgentThinking;
            FAgent.OnToolCall := @HandleAgentToolCall;
            FAgent.OnToolResult := @HandleAgentToolResult;
            FAgent.OnFinish := @HandleAgentFinish;
            FAgent.OnExecCommand := @HandleAgentExecCommand;
            FAgent.OnAskUser := @HandleAgentAskUser;
            try
              FAgent.RunAsync(Payload);
              // Pump events and watch for Esc so user can cancel
              CancelledShown := False;
              while not FAgent.Done do
              begin
                CheckSynchronize(50);
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
              FPrevAgentOnChunk := nil;
              FPrevAgentOnThinking := nil;
              FPrevAgentOnToolCall := nil;
              FPrevAgentOnToolResult := nil;
              FPrevAgentOnFinish := nil;
              FPrevAgentOnExecCommand := nil;
              FPrevAgentOnAskUser := nil;
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
  ChS: RawByteString;
  CursorPos, HistIndex, PromptRow, PromptCol, OldLen: Integer;
  C: WideChar;
  Wide: UnicodeString;

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

  procedure Redraw;
  var
    DisplayPrefix: RawByteString;
  begin
    // Hide cursor, redraw only input area, then show at final position
    HideConsoleCursor;
    ConGotoXY(PromptCol, PromptRow);
    ConClearLineFromCursor;
    ConWriteUtf8(Line);
    DisplayPrefix := Copy(Line, 1, CursorPos);
    ConGotoXY(PromptCol + Utf8CharCount(DisplayPrefix), PromptRow);
    ShowConsoleCursor;
  end;

begin
  Result := '';
  Rec := Default(INPUT_RECORD);
  Line := '';
  // Force UTF-8 tag so raw inserts do not get re-encoded later
  SetCodePage(Line, CP_UTF8, False);
  CursorPos := 0;
  HistIndex := FHistory.Count;

  PromptText := GetPromptText;
  // Ensure prompt starts on a fresh line after streaming output
  if not FLastCharWasNewLine then
    ConWriteUtf8(LineEnding);
  ConWriteUtf8(PromptText);
  FLastCharWasNewLine := False;
  PromptRow := ConWhereY;
  PromptCol := Utf8CharCount(PromptText) + 1;

  Handle := GetStdHandle(STD_INPUT_HANDLE);

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

    case Rec.Event.KeyEvent.wVirtualKeyCode of
      VK_RETURN:
        begin
          ConWriteUtf8(LineEnding);
          FLastCharWasNewLine := True;
          Break;
        end;
      VK_BACK:
        if CursorPos > 0 then
        begin
          CursorPos := Utf8PrevPos(Line, CursorPos);
          Delete(Line, CursorPos + 1, Utf8NextPos(Line, CursorPos + 1) - CursorPos - 1);
        end;
      VK_DELETE:
        // Delete current history entry if navigated but not edited
        if (HistIndex >= 0) and (HistIndex < FHistory.Count) and (Line = FHistory[HistIndex]) then
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
          Delete(Line, CursorPos + 1, Utf8NextPos(Line, CursorPos + 1) - CursorPos - 1);
      VK_LEFT:
        if CursorPos > 0 then
          CursorPos := Utf8PrevPos(Line, CursorPos);
      VK_RIGHT:
        if CursorPos < Length(Line) then
          CursorPos := Utf8NextPos(Line, CursorPos + 1);
      VK_HOME:
        CursorPos := 0;
      VK_END:
        CursorPos := Length(Line);
      VK_UP:
        if HistIndex > 0 then
        begin
          Dec(HistIndex);
          Line := FHistory[HistIndex];
          SetCodePage(Line, CP_UTF8, False);
          CursorPos := Length(Line);
        end;
      VK_DOWN:
        if HistIndex < FHistory.Count - 1 then
        begin
          Inc(HistIndex);
          Line := FHistory[HistIndex];
          SetCodePage(Line, CP_UTF8, False);
          CursorPos := Length(Line);
        end
        else if HistIndex < FHistory.Count then
        begin
          HistIndex := FHistory.Count;
          Line := '';
          CursorPos := 0;
        end;
      VK_ESCAPE:
        begin
          Line := '';
          CursorPos := 0;
        end;
      VK_C:
        if (Rec.Event.KeyEvent.dwControlKeyState and
            (LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED)) <> 0 then
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
          PromptCol := Utf8CharCount(PromptText) + 1;
          Continue;
        end
        else if Ord(C) >= 32 then
        begin
          ChS := WideCharToUtf8(C);
          OldLen := Length(Line);
          Insert(ChS, Line, CursorPos + 1);
          SetCodePage(Line, CP_UTF8, False);
          Inc(CursorPos, Length(Line) - OldLen);
        end;
    else
      if Ord(C) >= 32 then
      begin
        ChS := WideCharToUtf8(C);
        OldLen := Length(Line);
        Insert(ChS, Line, CursorPos + 1);
        SetCodePage(Line, CP_UTF8, False);
        Inc(CursorPos, Length(Line) - OldLen);
      end;
    end;

    Redraw;
  end;

  Result := Line;
  AddToHistory(Result);
end;

{$ELSE}

procedure TCustomTermManager.SetColor(AColor: TTermColor);
begin
  // No-op on non-Windows, override to emit ANSI escape sequences
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
