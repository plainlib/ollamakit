//-----------------------------------------------------------------------------------
//  OllamaKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit TermManager;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, DateUtils, Process, OllamaAgent{$IFDEF WINDOWS}, Windows{$ENDIF};

type
  // Classification of a single input line
  TTermInputKind = (tikEmpty, tikBuiltin, tikCommand, tikAgent);

  TTermRouteEvent = procedure(Sender: TObject; const ALine, APayload: string; var AKind: TTermInputKind; var AAllow: boolean) of object;
  TTermOutputEvent = procedure(Sender: TObject; const AText: string; AIsStderr: boolean) of object;
  TTermAgentEvent = procedure(Sender: TObject; const AText: string) of object;
  TTermExitEvent = procedure(Sender: TObject; AExitCode: integer) of object;

  TCustomTermManager = class(TComponent)
  private
    FPath: string;
    FPrompt: string;
    FWelcome: TCaption;
    // True when last written char was CR or LF, used to keep prompt on fresh line
    FLastCharWasNewLine: boolean;
    // Remove emoji and symbol chars that console fonts cannot render
    FStripEmoji: boolean;
    FBuiltinCommands: TStringList;
    FHistory: TStringList;
    FHistoryMax: integer;
    FShellExec: string;
    FCommandTimeout: integer;
    FUsePrefixes: boolean;
    FSearchPath: boolean;
    FRunning: boolean;
    FLastExitCode: integer;
    // Attached agent used to answer agent-classified input
    FAgent: TOllamaAgent;
    // Previous agent handlers, restored when agent is detached
    FPrevAgentOnChunk: TAgentChunkEvent;
    FPrevAgentOnFinish: TAgentFinishEvent;
    FPrevAgentOnExecCommand: TAgentExecCommandEvent;
    FOnRoute: TTermRouteEvent;
    FOnOutput: TTermOutputEvent;
    FOnAgentExecute: TTermAgentEvent;
    FOnExit: TTermExitEvent;
    procedure SetPath(const AValue: string);
    procedure SetAgent(const AValue: TOllamaAgent);
  protected
    // Clears agent reference when it is removed at runtime
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
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
    // Finalizes console line after agent run
    procedure HandleAgentFinish(Sender: TObject; AReason: TAgentFinishReason; const AAnswer, AErrorMsg: string);
    // Executes agent shell command through configured shell and returns output
    procedure HandleAgentExecCommand(Sender: TObject; const ACommand: string; var AResult: string; var AAllow: boolean);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Starts the interactive loop and blocks until exit
    procedure Run; virtual;
    // Requests the loop to stop after current iteration
    procedure Stop; virtual;
    // Runs shell command capturing output as UTF-8, returns combined stdout and stderr
    function ExecuteCommandCapture(const ACommand: string; out AExitCode: integer): string; virtual;
    // Writes raw text without line ending, flushes for streaming output
    procedure WriteText(const AText: string; AIsStderr: boolean = False); virtual;
    // Writes text followed by a line ending, flushes immediately
    procedure WriteLine(const AText: string; AIsStderr: boolean = False); virtual;
    // Working directory shared by shell and agent, empty means process cwd
    property Path: string read FPath write SetPath;
    // Prompt template with {path} placeholder
    property Prompt: string read FPrompt write FPrompt;
    // Banner printed once before the first prompt
    property Welcome: TCaption read FWelcome write FWelcome;
    // Replace emoji and unsupported symbols with nothing on output
    property StripEmoji: boolean read FStripEmoji write FStripEmoji default True;
    // Commands handled internally without invoking the shell
    property BuiltinCommands: TStringList read FBuiltinCommands;
    // Maximum number of lines kept in history buffer
    property HistoryMax: integer read FHistoryMax write FHistoryMax default 200;
    // Shell executable used for external commands
    property ShellExec: string read FShellExec write FShellExec;
    // Command timeout in milliseconds, zero means no limit
    property CommandTimeout: integer read FCommandTimeout write FCommandTimeout default 0;
    // Enable ! and ? prefixes to force routing
    property UsePrefixes: boolean read FUsePrefixes write FUsePrefixes default True;
    // Search PATH and known shell builtins during classification
    property SearchPath: boolean read FSearchPath write FSearchPath default True;
    // Exit code of the last executed external command
    property LastExitCode: integer read FLastExitCode;
    // True while the input loop is active
    property Running: boolean read FRunning;
    // Fires before action; host may approve or change kind
    property OnRoute: TTermRouteEvent read FOnRoute write FOnRoute;
    // Fires for every chunk of command output
    property OnOutput: TTermOutputEvent read FOnOutput write FOnOutput;
    // Fires when input is classified as agent text
    property OnAgentExecute: TTermAgentEvent read FOnAgentExecute write FOnAgentExecute;
    // Fires when the input loop finishes
    property OnExit: TTermExitEvent read FOnExit write FOnExit;
    // Optional agent that answers agent-classified input
    property Agent: TOllamaAgent read FAgent write SetAgent;
  end;

  TTermManager = class(TCustomTermManager)
  published
    // Working directory shared by shell and agent, empty means process cwd
    property Path;
    // Prompt template, {path} is replaced with Path
    property Prompt;
    // Banner printed once before the first prompt
    property Welcome;
    // Remove emoji and unsupported symbols before writing to console
    property StripEmoji;
    // List of commands handled internally without shell
    property BuiltinCommands;
    // Maximum number of lines kept in history buffer
    property HistoryMax;
    // Shell executable used for external commands
    property ShellExec;
    // Command timeout in milliseconds, zero means no limit
    property CommandTimeout;
    // Enable ! and ? prefixes to force command or agent routing
    property UsePrefixes;
    // Also search PATH and known shell builtins when routing
    property SearchPath;
    // Fires before action, host can approve or change kind
    property OnRoute;
    // Fires for every chunk of command output
    property OnOutput;
    // Fires when input is classified as agent text
    property OnAgentExecute;
    // Fires when the input loop finishes
    property OnExit;
    // Optional agent used to answer agent-classified input
    property Agent;
  end;

implementation

// Buffer type for piping output with zero-initialization
type
  TTermBuffer = array[0..4095] of byte;

// Forward declarations for helpers used before their definition
procedure ClearScreen; forward;
function CheckAndConsumeInterrupt: boolean; forward;
function CheckAndConsumeEsc: boolean; forward;
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
  // Result points to the start byte of the previous character
  // For multi-byte starts still need to step back once to be before it
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
    // Non-BMP surrogate pairs, all emoji live above U+FFFF
    if (Code >= $D800) and (Code <= $DFFF) then
      Continue;
    // Technical symbols, misc symbols and dingbats, arrows
    if (Code >= $2300) and (Code <= $23FF) then
      Continue;
    if (Code >= $2600) and (Code <= $27BF) then
      Continue;
    if (Code >= $2B00) and (Code <= $2BFF) then
      Continue;
    // Zero-width joiner and variation selectors
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

{ TCustomTermManager }

constructor TCustomTermManager.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  // Empty Path means "use process current directory" at runtime
  FPath := '';
  FPrompt := '{path}> ';
  FWelcome := '';
  FLastCharWasNewLine := True;
  FStripEmoji := True;
  FAgent := nil;
  FPrevAgentOnChunk := nil;
  FPrevAgentOnFinish := nil;
  FPrevAgentOnExecCommand := nil;
  FBuiltinCommands := TStringList.Create;
  FBuiltinCommands.Add('cd');
  FBuiltinCommands.Add('pwd');
  FBuiltinCommands.Add('cls');
  FBuiltinCommands.Add('clear');
  FBuiltinCommands.Add('help');
  FBuiltinCommands.Add('history');
  FBuiltinCommands.Add('exit');
  FBuiltinCommands.Add('quit');
  FHistory := TStringList.Create;
  FHistoryMax := 200;
  FShellExec := 'cmd.exe';
  FCommandTimeout := 0;
  FUsePrefixes := True;
  FSearchPath := True;
  FRunning := False;
  FLastExitCode := 0;
end;

destructor TCustomTermManager.Destroy;
begin
  SetAgent(nil);
  FHistory.Free;
  FBuiltinCommands.Free;
  inherited Destroy;
end;

procedure TCustomTermManager.SetPath(const AValue: string);
var
  NewPath: string;
begin
  // Empty value means "use process current directory"
  if AValue = '' then
  begin
    FPath := '';
    Exit;
  end;
  NewPath := ExpandFileName(AValue);
  if DirectoryExists(NewPath) then
  begin
    NewPath := ExcludeTrailingPathDelimiter(NewPath);
    // Keep drive root as C:\ instead of C: like cmd.exe
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

procedure TCustomTermManager.SetAgent(const AValue: TOllamaAgent);
begin
  if FAgent = AValue then
    Exit;
  if Assigned(FAgent) then
    FAgent.RemoveFreeNotification(Self);
  FAgent := AValue;
  FPrevAgentOnChunk := nil;
  FPrevAgentOnFinish := nil;
  FPrevAgentOnExecCommand := nil;
  if Assigned(FAgent) then
  begin
    FAgent.FreeNotification(Self);
    // Share terminal directory with agent file tools at runtime only
    if not (csDesigning in ComponentState) and (FAgent.RootPath = '') then
      FAgent.RootPath := GetEffectivePath;
  end;
end;

procedure TCustomTermManager.HandleAgentChunk(Sender: TObject; const AText: string);
begin
  WriteText(AText, False);
  if Assigned(FPrevAgentOnChunk) then
    FPrevAgentOnChunk(Sender, AText);
end;

procedure TCustomTermManager.HandleAgentFinish(Sender: TObject; AReason: TAgentFinishReason; const AAnswer, AErrorMsg: string);
var
  Streamed: boolean;
begin
  Streamed := Assigned(FAgent) and (afStreaming in FAgent.Features);
  case AReason of
    afrSuccess:
    begin
      // Signal empty response so the user is not left with silence
      if AAnswer = '' then
        WriteLine('[empty response from model]', True)
      else if not Streamed then
        WriteLine(AAnswer, False)
      else if not FLastCharWasNewLine then
        WriteLine('', False);
    end;
    afrCancelled:
      WriteLine('^C', True);
    afrMaxSteps:
      WriteLine('[max steps reached]', True);
    afrError:
      WriteLine('[error: ' + AErrorMsg + ']', True);
    afrModelNotSet:
      WriteLine('[agent not configured: ' + AErrorMsg + ']', True);
  end;
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
  AResult := ExecuteCommandCapture(ACommand, ExitCode);
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
begin
  Result := StringReplace(FPrompt, '{path}', GetEffectivePath, [rfReplaceAll]);
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
  else if Cmd = 'cd' then
  begin
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
    // Clear agent conversation history together with the screen
    if Assigned(FAgent) then
      FAgent.ClearHistory;
    ClearScreen;
  end
  else if Cmd = 'history' then
  begin
    for I := 0 to FHistory.Count - 1 do
      DoOutput(Format('%4d  %s%s', [I + 1, FHistory[I], LineEnding]), False);
  end
  else if Cmd = 'help' then
    DoOutput('Built-in: ' + FBuiltinCommands.CommaText + LineEnding, False)
  else
    DoOutput('Unknown builtin: ' + Cmd + LineEnding, True);
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
  // Explicit init silences the "not initialized" hint
  Buffer: TTermBuffer;
  BytesRead: longint;
  RawData: rawbytestring;
  StartTime: TDateTime;
  N: integer;
begin
  Result := -1;
  Buffer := Default(TTermBuffer);
  if ACommand = '' then
    Exit;
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
      if CheckAndConsumeInterrupt then
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

function TCustomTermManager.ExecuteCommandCapture(const ACommand: string; out AExitCode: integer): string;
var
  Process: TProcess;
  Buffer: TTermBuffer;
  BytesRead: longint;
  RawData, Captured, Tmp: rawbytestring;
  StartTime: TDateTime;
  N: integer;
begin
  Result := '';
  RawData := '';
  AExitCode := -1;
  Buffer := Default(TTermBuffer);
  if ACommand = '' then
    Exit;
  Captured := '';
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
        Break;
      end;

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
          Captured := Captured + RawData;
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
          Captured := Captured + RawData;
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
        Captured := Captured + RawData;
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
        Captured := Captured + RawData;
      end;
    end;

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
  // Print banner once before the loop if host configured one
  if FWelcome <> '' then
    DoOutput(FWelcome + LineEnding, False);
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
            FPrevAgentOnFinish := FAgent.OnFinish;
            FPrevAgentOnExecCommand := FAgent.OnExecCommand;
            FAgent.OnChunk := @HandleAgentChunk;
            FAgent.OnFinish := @HandleAgentFinish;
            FAgent.OnExecCommand := @HandleAgentExecCommand;
            try
              FAgent.RunAsync(Payload);
              // Pump events and watch for ESC so user can cancel
              CancelledShown := False;
              while not FAgent.Done do
              begin
                CheckSynchronize(50);
                if not CancelledShown and CheckAndConsumeEsc then
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
              FAgent.OnFinish := FPrevAgentOnFinish;
              FAgent.OnExecCommand := FPrevAgentOnExecCommand;
              FPrevAgentOnChunk := nil;
              FPrevAgentOnFinish := nil;
              FPrevAgentOnExecCommand := nil;
            end;
          end
          else
            DoAgentExecute(Payload);
      end;
    end;
  finally
    {$IFDEF WINDOWS}
    if InModeSaved then
      SetConsoleMode(InHandle, InMode);
    {$ENDIF}
  end;
  DoExit(FLastExitCode);
end;

procedure TCustomTermManager.Stop;
begin
  FRunning := False;
end;

{$IFDEF WINDOWS}

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
  // Explicit init silences the "not initialized" hint
  Info: TConsoleScreenBufferInfo;
begin
  Result := 1;
  Info := Default(TConsoleScreenBufferInfo);
  if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info) then
    Result := Info.dwCursorPosition.Y + 1;
end;

procedure ConClearLineFromCursor;
var
  // Explicit init silences the "not initialized" hint
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
  // Explicit init silences the "not initialized" hint
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

function CheckAndConsumeInterrupt: Boolean;
var
  Handle: THandle;
  // Explicit init silences the "not initialized" hint
  Rec: INPUT_RECORD;
  N: DWORD = 0;
begin
  Result := False;
  Rec := Default(INPUT_RECORD);
  Handle := GetStdHandle(STD_INPUT_HANDLE);
  if not PeekConsoleInput(Handle, Rec, 1, N) then
    Exit;
  if N = 0 then
    Exit;
  if Rec.EventType <> KEY_EVENT then
    Exit;
  if not Rec.Event.KeyEvent.bKeyDown then
    Exit;
  if Rec.Event.KeyEvent.wVirtualKeyCode = VK_ESCAPE then
  begin
    ReadConsoleInput(Handle, Rec, 1, N);
    Result := True;
  end
  else if (Rec.Event.KeyEvent.wVirtualKeyCode = VK_C) and
    ((Rec.Event.KeyEvent.dwControlKeyState and
      (LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED)) <> 0) then
  begin
    ReadConsoleInput(Handle, Rec, 1, N);
    Result := True;
  end;
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

function CheckAndConsumeEsc: boolean;
var
  Handle: THandle;
  Rec: INPUT_RECORD;
  N: DWORD;
begin
  Result := False;
  Rec := Default(INPUT_RECORD);
  N := 0;
  Handle := GetStdHandle(STD_INPUT_HANDLE);
  if not PeekConsoleInput(Handle, Rec, 1, N) then
    Exit;
  if N = 0 then
    Exit;
  if Rec.EventType <> KEY_EVENT then
    Exit;
  if not Rec.Event.KeyEvent.bKeyDown then
    Exit;
  if Rec.Event.KeyEvent.wVirtualKeyCode = VK_ESCAPE then
  begin
    ReadConsoleInput(Handle, Rec, 1, N);
    Result := True;
  end;
end;

function TCustomTermManager.ReadLine: string;
var
  Handle: THandle;
  // Explicit init silences the "not initialized" hint
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
    WAIT_TIMEOUT_MS = 10;
  var
    Raw: RawByteString;
    B, Nb, Attempts: Integer;
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
    while (Nb > 0) and not Skip do
    begin
      Attempts := 0;
      // Poll the input queue in short intervals instead of blocking
      while Attempts < WAIT_TIMEOUT_MS do
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
        if (NextRec.EventType <> KEY_EVENT) or (not NextRec.Event.KeyEvent.bKeyDown) then
        begin
          Skip := True;
          Break;
        end;
        B := Ord(NextRec.Event.KeyEvent.UnicodeChar) and $FF;
        if (B < $80) or (B > $BF) then
        begin
          // Next event is not a continuation byte, sequence is broken
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
    // Conhost with UTF-8 CP wraps each raw byte as $FFxx, collect sequence
    if Ord(C) >= $FF00 then
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
          Delete(Line, CursorPos + 1,
            Utf8NextPos(Line, CursorPos + 1) - CursorPos - 1);
        end;
      VK_DELETE:
        // Delete current history entry if navigated but not edited
        if (HistIndex >= 0) and (HistIndex < FHistory.Count) and
           (Line = FHistory[HistIndex]) then
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
          Delete(Line, CursorPos + 1,
            Utf8NextPos(Line, CursorPos + 1) - CursorPos - 1);
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
          // History strings come from AddToHistory, retag as UTF-8
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

function CheckAndConsumeInterrupt: boolean;
begin
  Result := False;
end;

function CheckAndConsumeEsc: boolean;
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
