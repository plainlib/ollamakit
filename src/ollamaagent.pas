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
  TAgentFeature = (afStreaming, afFileTools, afExecCommand);
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

type
  TOllamaAgent = class;

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
    FOwner: TOllamaAgent;
    function GetItem(AIndex: integer): TAgentTool;
    procedure SetItem(AIndex: integer; const AValue: TAgentTool);
  protected
    function GetOwner: TPersistent; override;
  public
    constructor Create(AOwner: TOllamaAgent);
    function Add: TAgentTool;
    property Items[AIndex: integer]: TAgentTool read GetItem write SetItem; default;
  end;

  // LLM agent with tool-calling loop, independent of any terminal component
  TOllamaAgent = class(TComponent)
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
    FOnRoute: TAgentRouteEvent;
    FOnChunk: TAgentChunkEvent;
    FOnThinking: TAgentThinkingEvent;
    FOnToolCall: TAgentToolCallEvent;
    FOnToolResult: TAgentToolResultEvent;
    FOnExecCommand: TAgentExecCommandEvent;
    FOnFinish: TAgentFinishEvent;
    procedure SetOllamaManager(const AValue: TOllamaManager);
    procedure SetTools(const AValue: TAgentTools);
    function GetRootPath: string;
    procedure SetRootPath(const AValue: string);
    function GetHistory: string;
    procedure SetHistory(const AValue: string);
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
    // True while an agent run is in progress
    property Done: boolean read FDone;
    // Text returned by the last run
    property FinalAnswer: string read FFinalAnswer;
    // JSON array of accumulated messages when KeepHistory is enabled
    property History: string read GetHistory write SetHistory;
  published
    // Ollama API client used for chat requests
    property OllamaManager: TOllamaManager read FOllamaManager write SetOllamaManager;
    // Model name passed to Ollama, e.g. qwen2.5-coder:7b
    property ModelName: string read FModelName write FModelName;
    // System message sent before the conversation
    property SystemPrompt: TCaption read FSystemPrompt write FSystemPrompt;
    // Maximum number of agent iterations before giving up
    property MaxSteps: integer read FMaxSteps write FMaxSteps default 20;
    // Per-request timeout in ms, 0 means use OllamaManager default
    property RequestTimeout: integer read FRequestTimeout write FRequestTimeout default 0;
    // Feature toggles for streaming, file tools and shell execution
    property Features: TAgentFeatures read FFeatures write FFeatures default [afStreaming, afFileTools];
    // Sandbox directory for file tools, empty means process cwd
    property RootPath: string read GetRootPath write SetRootPath;
    // Collection of user-defined tools
    property Tools: TAgentTools read FTools write SetTools;
    // When True, messages persist between RunAsync calls
    property KeepHistory: boolean read FKeepHistory write FKeepHistory default False;
    // When True, the agent logs every step and event to stderr
    property Log: boolean read FLog write FLog default False;
    // Fired before chat step and each tool call, host may reject
    property OnRoute: TAgentRouteEvent read FOnRoute write FOnRoute;
    // Fired for every streamed text chunk from the model
    property OnChunk: TAgentChunkEvent read FOnChunk write FOnChunk;
    // Fired for every thinking chunk from the model
    property OnThinking: TAgentThinkingEvent read FOnThinking write FOnThinking;
    // Fired when the LLM requests a tool, after host approval
    property OnToolCall: TAgentToolCallEvent read FOnToolCall write FOnToolCall;
    // Fired with the tool result before it is sent back to the model
    property OnToolResult: TAgentToolResultEvent read FOnToolResult write FOnToolResult;
    // Fired for exec_command tool, host executes and returns the output
    property OnExecCommand: TAgentExecCommandEvent read FOnExecCommand write FOnExecCommand;
    // Fired once when the run terminates for any reason
    property OnFinish: TAgentFinishEvent read FOnFinish write FOnFinish;
  end;

implementation

uses
  FileUtil, Math;

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

type
  // Holder for async event delivery through TThread.Queue
  TAgentCallBase = class
  public
    Agent: TOllamaAgent;
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
    FAgent: TOllamaAgent;
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
    constructor Create(AAgent: TOllamaAgent; const AUserText: string);
  end;

  { TOllamaAgentThread }

constructor TOllamaAgentThread.Create(AAgent: TOllamaAgent; const AUserText: string);
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
  Step, I, SavedTimeout: integer;
  MessagesArr: TJSONArray;
  MessagesJson, ToolsJson, FinalJson, ErrMsg: string;
  Kind: TOllamaErrorKind;
  Allow: boolean;
  Reason: TAgentFinishReason;
  Data, MessageData, ToolCallsData, FuncData, ArgsData: TJSONData;
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
        MsgObj.Add('content', string(FAgent.SystemPrompt));
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
            // Ignore invalid history
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
      FAgent.LogLine(Format('Features: streaming=%s fileTools=%s exec=%s',
        [BoolToStr(afStreaming in FAgent.FFeatures, 'on', 'off'), BoolToStr(afFileTools in FAgent.FFeatures, 'on', 'off'),
        BoolToStr(afExecCommand in FAgent.FFeatures, 'on', 'off')]));
      FAgent.LogLine(Format('Tools schema len=%d names=[%s]', [Length(ToolsJson), FAgent.BuildToolsNames]));

      for Step := 1 to FAgent.MaxSteps do
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

        FAgent.LogLine(Format('Chat done raw_len=%d', [Length(FinalJson)]));

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
              ToolResult := FAgent.DispatchTool(ToolName, ToolArgs)
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
        // Ignore history save errors
      end;
    end;
    MessagesArr.Free;
    QueueFinish(Reason, FAgent.FFinalAnswer, ErrMsg);
    FAgent.FDone := True;
  end;
end;

{ TAgentTools }

constructor TAgentTools.Create(AOwner: TOllamaAgent);
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

{ TOllamaAgent }

constructor TOllamaAgent.Create(AOwner: TComponent);
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
  FTools := TAgentTools.Create(Self);
end;

destructor TOllamaAgent.Destroy;
begin
  // Wait for any running thread to finish
  while not FDone do
    CheckSynchronize(50);
  // Drain any queued events so they do not fire after Free
  CheckSynchronize(0);
  FTools.Free;
  inherited Destroy;
end;

procedure TOllamaAgent.SetOllamaManager(const AValue: TOllamaManager);
begin
  if FOllamaManager = AValue then
    Exit;
  if Assigned(FOllamaManager) then
    FOllamaManager.RemoveFreeNotification(Self);
  FOllamaManager := AValue;
  if Assigned(FOllamaManager) then
    FOllamaManager.FreeNotification(Self);
end;

procedure TOllamaAgent.SetTools(const AValue: TAgentTools);
begin
  FTools.Assign(AValue);
end;

procedure TOllamaAgent.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FOllamaManager) then
    FOllamaManager := nil;
end;

function TOllamaAgent.GetRootPath: string;
begin
  Result := FRootPath;
end;

procedure TOllamaAgent.SetRootPath(const AValue: string);
begin
  if FRootPath = AValue then
    Exit;
  FRootPath := AValue;
end;

function TOllamaAgent.GetHistory: string;
begin
  Result := FHistory;
end;

procedure TOllamaAgent.SetHistory(const AValue: string);
begin
  FHistory := AValue;
end;

procedure TOllamaAgent.RunAsync(const AText: string);
begin
  if not FDone then
    Exit;
  FDone := False;
  FCancelled := False;
  FFinalAnswer := '';
  TOllamaAgentThread.Create(Self, AText);
end;

function TOllamaAgent.Run(const AText: string): string;
begin
  RunAsync(AText);
  while not FDone do
    CheckSynchronize(50);
  CheckSynchronize(0);
  Result := FFinalAnswer;
end;

procedure TOllamaAgent.Cancel;
begin
  FCancelled := True;
end;

procedure TOllamaAgent.ClearHistory;
begin
  FHistory := '';
end;

procedure TOllamaAgent.LogLine(const AText: string);
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

function TOllamaAgent.GetEffectiveRootPath: string;
begin
  if FRootPath <> '' then
    Result := ExpandFileName(FRootPath)
  else
    Result := GetCurrentDir;
end;

function TOllamaAgent.SafePath(const ARelPath: string): string;
var
  Root, Full: string;
begin
  Result := '';
  Root := IncludeTrailingPathDelimiter(GetEffectiveRootPath);
  if Trim(ARelPath) = '' then
    Exit(Root);
  Full := ExpandFileName(Root + ARelPath);
  // Compare with trailing delimiter so '.' resolves to root itself
  if Pos(LowerCase(Root), LowerCase(IncludeTrailingPathDelimiter(Full))) = 1 then
    Result := Full;
end;

function TOllamaAgent.BuildToolsSchemaJson: string;

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
      AddTool(Arr, 'write_file', 'Write contents to a file inside the workspace',
        '{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}');
      AddTool(Arr, 'list_files', 'List files in a directory inside the workspace',
        '{"type":"object","properties":{"path":{"type":"string","description":"Optional relative directory"}}}');
      AddTool(Arr, 'search_text', 'Search for a text pattern in files',
        '{"type":"object","properties":{"path":{"type":"string"},"pattern":{"type":"string"},"recursive":{"type":"boolean"}},"required":["pattern"]}');
    end;

    if afExecCommand in FFeatures then
      AddTool(Arr, 'exec_command', 'Execute a shell command and return output',
        '{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}');

    if Arr.Count > 0 then
      Result := Arr.AsJSON;
  finally
    Arr.Free;
  end;
end;

function TOllamaAgent.BuildToolsNames: string;
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
    end;
    if afExecCommand in FFeatures then
      Names.Add('exec_command');
    Result := Names.CommaText;
  finally
    Names.Free;
  end;
end;

function TOllamaAgent.DoReadFile(AArgs: TJSONObject): string;
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
    Result := '{"error": "path outside workspace"}';
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

function TOllamaAgent.DoWriteFile(AArgs: TJSONObject): string;
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
    Result := '{"error": "path outside workspace"}';
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

function TOllamaAgent.DoListFiles(AArgs: TJSONObject): string;
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
    Result := '{"error": "path outside workspace"}';
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

function TOllamaAgent.DoSearchText(AArgs: TJSONObject): string;
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
    Result := '{"error": "path outside workspace"}';
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

function TOllamaAgent.DispatchTool(const AName, AArgsJson: string): string;
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

    if (AName = 'read_file') and (afFileTools in FFeatures) then
      Exit(DoReadFile(Args))
    else if (AName = 'write_file') and (afFileTools in FFeatures) then
      Exit(DoWriteFile(Args))
    else if (AName = 'list_files') and (afFileTools in FFeatures) then
      Exit(DoListFiles(Args))
    else if (AName = 'search_text') and (afFileTools in FFeatures) then
      Exit(DoSearchText(Args))
    else if (AName = 'exec_command') and (afExecCommand in FFeatures) then
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

    Result := '{"error": "unknown tool: ' + AName + '"}';
  finally
    Args.Free;
  end;
end;

end.
