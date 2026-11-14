//-----------------------------------------------------------------------------------
//  OllamaKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit OllamaAgent;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, fpjson, jsonparser, OllamaManager;

type
  // Feature toggles controlled by the Features set property
  TAgentFeature = (
    // Stream content and thinking chunks to OnChunk and OnThinking in real time
    afStreaming,
    // Enable built-in file tools: read, write, edit, delete, move, copy, list, find, grep
    afFileTools,
    // Enable exec_command tool, host runs the shell command via OnExecCommand
    afExecCommand,
    // Enable git tools: status, diff, log, commit, all executed through OnExecCommand
    afGit,
    // Enable ask_user tool, host shows the question and returns the answer via OnAskUser
    afInteractive,
    // Enable finish tool, model can declare the task complete and return a final message
    afFinish
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

type
  TCustomOllamaAgent = class;

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
    FRootPath: string;
    FTools: TAgentTools;
    FKeepHistory: boolean;
    FHistory: string;
    FDone: boolean;
    FCancelled: boolean;
    FFinalAnswer: string;
    FLog: boolean;
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
    procedure SetOllamaManager(const AValue: TOllamaManager);
    procedure SetTools(const AValue: TAgentTools);
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
    // Resolves placeholders in SystemPrompt using current values
    function BuildSystemPrompt: string; virtual;
    // Resets usage counters in the manager and this agent
    procedure ResetUsage;

    property Done: boolean read FDone;
    property FinalAnswer: string read FFinalAnswer;
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
    property Features: TAgentFeatures read FFeatures write FFeatures default [afStreaming, afFileTools];
    property RootPath: string read GetRootPath write SetRootPath;
    property Tools: TAgentTools read FTools write SetTools;
    property KeepHistory: boolean read FKeepHistory write FKeepHistory default False;
    property Log: boolean read FLog write FLog default False;
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
    // Feature toggles for streaming, file tools and shell execution
    property Features;
    // Sandbox directory for file tools, empty means process cwd
    property RootPath;
    // Collection of user-defined tools
    property Tools;
    // When True, messages persist between RunAsync calls
    property KeepHistory;
    // When True, the agent logs every step and event to stderr
    property Log;
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
  FileUtil, Math, RegExpr;

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
    WriteLn(ErrOutput, Text);
    Flush(ErrOutput);
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
  if afStreaming in FAgent.FFeatures then
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
  FAgent.LogLine(Format('Thinking chunk len=%d', [Length(AText)]));
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

      if FAgent.SystemPrompt <> '' then
      begin
        MsgObj := TJSONObject.Create;
        MsgObj.Add('role', 'system');
        // Resolve {path} and {model} against current values
        MsgObj.Add('content', FAgent.BuildSystemPrompt);
        MessagesArr.Add(MsgObj);
      end;

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
      MsgObj.Add('content', FUserText);
      MessagesArr.Add(MsgObj);

      ToolsJson := FAgent.BuildToolsSchemaJson;
      FAgent.LogLine(Format('Features: streaming=%s fileTools=%s exec=%s git=%s interactive=%s finish=%s',
        [BoolToStr(afStreaming in FAgent.FFeatures, 'on', 'off'), BoolToStr(afFileTools in FAgent.FFeatures, 'on', 'off'),
        BoolToStr(afExecCommand in FAgent.FFeatures, 'on', 'off'), BoolToStr(afGit in FAgent.FFeatures, 'on', 'off'),
        BoolToStr(afInteractive in FAgent.FFeatures, 'on', 'off'), BoolToStr(afFinish in FAgent.FFeatures, 'on', 'off')]));
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
        MessagesJson := MessagesArr.AsJSON;
        FAgent.LogLine(Format('Step %d messages=%d timeout=%d', [Step, MessagesArr.Count, FAgent.OllamaManager.RequestTimeout]));

        // Temporarily override manager timeout when agent has its own
        SavedTimeout := FAgent.OllamaManager.RequestTimeout;
        if FAgent.FRequestTimeout > 0 then
          FAgent.OllamaManager.RequestTimeout := FAgent.FRequestTimeout;
        try
          // Always stream, tool_calls are accumulated by the helper
          if afStreaming in FAgent.FFeatures then
            FinalJson := FAgent.OllamaManager.ChatStream(FAgent.ModelName, MessagesJson, ToolsJson,
              @HandleStreamChunk, @HandleThinkingChunk, Kind, ErrMsg)
          else
            // Streaming disabled, use non-streaming with full content chunk
            FinalJson := FAgent.OllamaManager.ChatWithTools(FAgent.ModelName, MessagesJson, ToolsJson,
              @HandleFullContent, @HandleThinkingChunk, Kind, ErrMsg);
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
          FAgent.LogLine(Format('Abort: chat error kind=%d msg="%s"', [Ord(Kind), ErrMsg]));
          Exit;
        end;

        // Update usage counters from the manager after each step
        FAgent.FContextUsed := FAgent.OllamaManager.LastUsageTotal;
        // Resolve context total from NumCtx or from loaded model info
        if FAgent.OllamaManager.NumCtx > 0 then
          FAgent.FContextTotal := FAgent.OllamaManager.NumCtx
        else if FAgent.FContextTotal = 0 then
        begin
          FAgent.FContextTotal := FAgent.OllamaManager.GetModelContextLength(FAgent.ModelName);
          // Model may have just been loaded, trigger a refresh for next step
          if (FAgent.FContextTotal = 0) and (Step = 1) then
            FAgent.OllamaManager.RefreshModels;
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
  FFeatures := [afStreaming, afFileTools];
  FRootPath := '';
  FKeepHistory := False;
  FHistory := '';
  FDone := True;
  FCancelled := False;
  FFinalAnswer := '';
  FLog := False;
  FContextUsed := 0;
  FContextTotal := 0;
  FOnAskUser := nil;
  FTools := TAgentTools.Create(Self);
end;

destructor TCustomOllamaAgent.Destroy;
begin
  // Wait for any running thread to finish
  while not FDone do
    CheckSynchronize(50);
  // Drain any queued events so they do not fire after Free
  CheckSynchronize(0);
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
  if Assigned(FOllamaManager) then
  begin
    // Explicit NumCtx wins, otherwise use loaded model context from /api/ps
    if FOllamaManager.NumCtx > 0 then
      FContextTotal := FOllamaManager.NumCtx
    else
      FContextTotal := FOllamaManager.GetModelContextLength(FModelName);
  end
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
begin
  Result := string(FSystemPrompt);
  Result := StringReplace(Result, '{path}', GetEffectiveRootPath, [rfReplaceAll]);
  Result := StringReplace(Result, '{model}', FModelName, [rfReplaceAll]);
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

procedure TCustomOllamaAgent.LogLine(const AText: string);
var
  Call: TLogCall;
begin
  if not FLog then
    Exit;
  // Already on the main thread, log synchronously to keep ordering
  if GetCurrentThreadID = MainThreadID then
  begin
    WriteLn(ErrOutput, '[agent] ', AText);
    Exit;
  end;
  Call := TLogCall.Create;
  Call.Agent := Self;
  Call.Text := '[agent] ' + AText;
  TThread.Queue(nil, @Call.Invoke);
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
      AddTool(Arr, 'read_file', 'Read contents of a file inside the workspace',
        '{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"}},"required":["path"]}');
      AddTool(Arr, 'write_file', 'Write contents to a file inside the workspace, creates parent directories',
        '{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}');
      AddTool(Arr, 'list_files', 'List files in a directory inside the workspace, non-recursive',
        '{"type":"object","properties":{"path":{"type":"string","description":"Optional relative directory"}}}');
      AddTool(Arr, 'search_text', 'Search for a literal text pattern in files, returns file and line',
        '{"type":"object","properties":{"path":{"type":"string"},"pattern":{"type":"string"},"recursive":{"type":"boolean"}},"required":["pattern"]}');
      AddTool(Arr, 'read_file_lines', 'Read a line range from a file, capped at 5000 lines per call',
        '{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":"integer"},"end_line":{"type":"integer"}},"required":["path"]}');
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
      AddTool(Arr, 'find_files', 'Find files by glob pattern, recursive by default, capped at 2000 results',
        '{"type":"object","properties":{"path":{"type":"string"},"pattern":{"type":"string"},"recursive":{"type":"boolean"}},"required":["pattern"]}');
      AddTool(Arr, 'grep', 'Search files by regex or literal pattern, capped at 500 matches',
        '{"type":"object","properties":{"path":{"type":"string"},"pattern":{"type":"string"},"recursive":{"type":"boolean"},"literal":{"type":"boolean"}},"required":["pattern"]}');
    end;

    if afExecCommand in FFeatures then
      AddTool(Arr, 'exec_command', 'Execute a shell command and return combined stdout and stderr',
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
    Result := Names.CommaText;
  finally
    Names.Free;
  end;
end;

function TCustomOllamaAgent.DoReadFile(AArgs: TJSONObject): string;
var
  RelPath, FullPath: string;
  Stream: TFileStream;
  Buf: TBytes = ();
  ReadCount: int64;
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
    SetLength(Buf, Min(Stream.Size, 100000));
    if Length(Buf) > 0 then
      ReadCount := Stream.Read(Buf[0], Length(Buf))
    else
      ReadCount := 0;
    SetLength(Buf, ReadCount);
    Result := TJSONString.Create(string(Buf)).AsJSON;
  finally
    Stream.Free;
  end;
end;

function TCustomOllamaAgent.DoWriteFile(AArgs: TJSONObject): string;
var
  RelPath, FullPath, Content: string;
  Stream: TFileStream;
  Bytes: TBytes;
begin
  Result := '{"error": "invalid arguments"}';
  if AArgs = nil then
    Exit;
  RelPath := AArgs.Get('path', '');
  Content := AArgs.Get('content', '');
  FullPath := SafePath(RelPath);
  if FullPath = '' then
  begin
    Result := '{"error": "path outside workspace, workspace is ' + GetEffectiveRootPath + ', use relative paths"}';
    Exit;
  end;
  ForceDirectories(ExtractFileDir(FullPath));
  Stream := TFileStream.Create(FullPath, fmCreate);
  try
    Bytes := TBytes(Content);
    if Length(Bytes) > 0 then
      Stream.Write(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  Result := '{"ok": true, "bytes": ' + IntToStr(Length(Content)) + '}';
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
  MAX_FILE_SIZE = 5 * 1024 * 1024;
var
  RelPath, FullPath, Pattern: string;
  Recursive, Literal, HasMatch: boolean;
  Files: TStringList;
  Matches: TJSONArray;
  FileLines: TStringList;
  I, J: integer;
  Line: string;
  MatchObj: TJSONObject;
  BaseRoot: string;
  Regex: TRegExpr;
  FileInfoRec: TSearchRec;

// Tests a line against the current pattern, literal or regex
  function LineMatches(const ALine: string): boolean;
  begin
    if Literal then
      Result := Pos(Pattern, ALine) > 0
    else
    begin
      Regex.Expression := Pattern;
      Result := Regex.Exec(ALine);
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
  if not DirectoryExists(FullPath) then
  begin
    Result := '{"error": "directory not found"}';
    Exit;
  end;
  BaseRoot := IncludeTrailingPathDelimiter(GetEffectiveRootPath);
  Regex := nil;
  if not Literal then
    Regex := TRegExpr.Create;
  Files := TStringList.Create;
  Matches := TJSONArray.Create;
  try
    FindAllFiles(Files, FullPath, '*.*', Recursive);
    for I := 0 to Files.Count - 1 do
    begin
      if Matches.Count >= MAX_MATCHES then
        Break;
      if FindFirst(Files[I], faAnyFile, FileInfoRec) = 0 then
      try
        if FileInfoRec.Size > MAX_FILE_SIZE then
          Continue;
      finally
        FindClose(FileInfoRec);
      end;
      FileLines := TStringList.Create;
      try
        try
          FileLines.LoadFromFile(Files[I]);
        except
          Continue;
        end;
        for J := 0 to FileLines.Count - 1 do
        begin
          if Matches.Count >= MAX_MATCHES then
            Break;
          Line := FileLines[J];
          try
            HasMatch := LineMatches(Line);
          except
            HasMatch := False;
          end;
          if HasMatch then
          begin
            MatchObj := TJSONObject.Create;
            MatchObj.Add('file', RelativeToRoot(BaseRoot, Files[I]));
            MatchObj.Add('line', J + 1);
            MatchObj.Add('text', Line);
            Matches.Add(MatchObj);
          end;
        end;
      finally
        FileLines.Free;
      end;
    end;
    Result := '{"count": ' + IntToStr(Matches.Count) + ', "truncated": ' + BoolToStr(Matches.Count >= MAX_MATCHES, 'true', 'false') +
      ', "matches": ' + Matches.AsJSON + '}';
  finally
    Matches.Free;
    Files.Free;
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

    // finish is handled in Execute before DispatchTool is called
    Result := '{"error": "unknown tool: ' + AName + '"}';
  finally
    Args.Free;
  end;
end;

end.
