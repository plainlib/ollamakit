//-----------------------------------------------------------------------------------
//  OllamaKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit OllamaManager;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Menus, Clipbrd, DateUtils, Dialogs, ExtCtrls, fpjson, jsonparser,
  Network, StringHelper, httpsend, blcksock;

type
  { Error kind reported by TOllamaErrorEvent }
  TOllamaErrorKind = (
    oekNone,          // no error
    oekUnknown,       // unknown error
    oekConnection,    // connection or socket failure
    oekTimeout,       // request timed out
    oekHttpClient,    // HTTP 4xx
    oekHttpServer,    // HTTP 5xx
    oekJson,          // invalid JSON response
    oekNotFound,      // resource (model) not found (HTTP 404)
    oekCancelled      // operation cancelled
    );

  { Toggleable sections of the popup menu }
  TOllamaMenuSection = (msPull, msKeepAlive, msServer, msModels, msConnect);
  TOllamaMenuSections = set of TOllamaMenuSection;

  { Event fired when the model list is refreshed }
  TModelsRefreshedEvent = procedure(Sender: TObject; const OldModels, NewModels: TStringList) of object;
  { Event fired on any error, never raises }
  TOllamaErrorEvent = procedure(Sender: TObject; Kind: TOllamaErrorKind; const ModelName: string; const ErrorMsg: string) of object;
  { Event fired when pull progress changes (simplified: only start/finish) }
  TPullProgressEvent = procedure(Sender: TObject; const ModelName: string; Percent: integer) of object;
  { Text callback for streaming chat, set ACancel to True to abort }
  TOllamaStreamCallback = procedure(const AContent: string; var ACancel: boolean) of object;
  { Event fired before a background refresh/connection attempt starts }
  TConnectingEvent = procedure(Sender: TObject) of object;
  { Event fired after a successful refresh/connection }
  TConnectedEvent = procedure(Sender: TObject) of object;
  // Occurs when a model start or stop operation completes.
  // Success indicates whether the operation completed successfully.
  TModelOperationEvent = procedure(Sender: TObject; const ModelName: string; External: boolean; Success: boolean;
    const ErrorMsg: string) of object;

  { Background operation kinds }
  TOllamaBgOp = (boPull, boStart, boStop, boRefresh);

  TCustomOllamaManager = class;

  { Helper that dispatches pull progress from a worker thread to the main thread }
  TPullProgressCall = class
  public
    Manager: TCustomOllamaManager;
    ModelName: string;
    Pct: integer;
    procedure Fire;
  end;

  { Helper that parses NDJSON pull stream chunks and updates progress }
  TPullStreamHelper = class
  public
    Manager: TCustomOllamaManager;
    ModelName: string;
    Buffer: string;
    Done: boolean;
    LastPct: integer;
    procedure HandleRaw(const AChunk: string; var ACancel: boolean);
  end;

  { Background worker for long-running Ollama operations }
  TOllamaBgThread = class(TThread)
  private
    FManager: TCustomOllamaManager;
    FModelName: string;
    FOp: TOllamaBgOp;
    FGen: integer;
    FErrorKind: TOllamaErrorKind;
    FErrorMsg: string;
    FTagsJson: string;
    FPsJson: string;
    procedure DoFinish;
  protected
    procedure Execute; override;
  public
    constructor Create(AManager: TCustomOllamaManager; AOp: TOllamaBgOp; const AModelName: string; AGen: integer = 0);
  end;

  { TCustomOllamaManager }

  TCustomOllamaManager = class(TComponent)
  private
    FBaseURL: string;
    FPopupMenu: TPopupMenu;
    FKeepAlive: integer;
    // num_ctx value sent with requests, 0 means use Ollama default
    FNumCtx: integer;
    // Prompt tokens reported by the last completed request
    FLastPromptEvalCount: integer;
    // Generated tokens reported by the last completed request
    FLastEvalCount: integer;
    // Diagnostics reported by the last completed request
    FLastRequestStats: string;
    FAutoRefresh: boolean;
    FConnectionTimeout: integer;
    FRequestTimeout: integer;
    FModelTimeout: integer;
    FPullTimeout: integer;
    FMenuSections: TOllamaMenuSections;

    FOnModelsRefreshed: TModelsRefreshedEvent;
    FOnError: TOllamaErrorEvent;
    FOnPullProgress: TPullProgressEvent;
    FOnConnecting: TConnectingEvent;
    FOnConnected: TConnectedEvent;
    FOnModelStart: TModelOperationEvent;
    FOnModelStop: TModelOperationEvent;

    // Internal state
    FInstalledModels: TStringList;
    FInstalledDetails: TStringList; // Name=Full JSON object from /api/tags
    FRunningModels: TStringList;
    FRunningDetails: TStringList;   // Name=Full JSON object from /api/ps
    FLoadingModels: TStringList;
    FStartingModels: TStringList;
    FStartingProgress: TStringList; // Name=Percent
    FPullProgress: TStringList;     // Name=Percent for pull operations
    FStartSubItems: TStringList;    // Name=Object (TMenuItem)
    FLoadingSubItems: TStringList;  // Name=Object (TMenuItem) for pull items
    FActiveThreads: TList;
    FProgressTimer: TTimer;
    FConnecting: boolean;
    FConnected: boolean;
    FModelsInitialized: boolean;
    FActive: boolean;
    FConnectGen: integer;
    FShutdown: boolean;
    FLastPopupTick: QWord;
    FWasConnectedAtPopup: boolean;

    // Monitor
    FMonitorTimer: TTimer;
    FMonitorModelState: boolean;
    FMonitorInterval: integer;
    FMonitorInitialized: boolean;
    FInternalModelChanges: TStringList;
    FPrevPopupHandler: TNotifyEvent;

    procedure MonitorTimerTick(Sender: TObject);
    procedure SetMonitorModelState(const Value: boolean);
    procedure SetMonitorInterval(const Value: integer);
    procedure ProcessModelStateChanges(const OldModels, NewModels: TStringList);

    // Popup menu handling
    procedure DoPopup(Sender: TObject);
    procedure BuildPopupMenu;
    procedure ClearPopupMenu;

    // HTTP helpers, none of these raise exceptions
    function DoRequest(AMethod: TWebMethod; const Endpoint, JsonBody: string; out Kind: TOllamaErrorKind;
      out ErrorMsg: string; ARequestTimeout: integer = 0): string;
    function ApiGet(const Endpoint: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): string;
    function ApiPost(const Endpoint, JsonBody: string; out Kind: TOllamaErrorKind; out ErrorMsg: string;
      ARequestTimeout: integer = 0): string;
    function RawDelete(const Endpoint, JsonBody: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean;
    function ParseModels(const JsonStr: string; ADetails: TStringList): TStringList;
    function ValidateModelsJson(const JsonStr: string): boolean;
    function IsCloudModel(const ModelName: string): boolean;
    function BuildModelInfo(const ModelName: string): string;

    // Returns GetLastUsageTotal for read-only property
    function GetLastUsageTotal: integer;
    // Builds optional "options" JSON fragment for num_ctx
    function BuildOptionsJson: string;
    // Error reporting helper
    procedure DoError(Kind: TOllamaErrorKind; const ModelName, Msg: string);

    // Connection lifecycle
    procedure BeginConnect;
    procedure ProcessRefreshData(const TagsJson, PsJson: string; Kind: TOllamaErrorKind; const ErrorMsg: string; AGen: integer);

    // Menu actions
    procedure MenuPullClick(Sender: TObject);
    procedure MenuServerClick(Sender: TObject);
    procedure MenuStartClick(Sender: TObject);
    procedure MenuStopClick(Sender: TObject);
    procedure MenuDeleteClick(Sender: TObject);
    procedure MenuCopyNameClick(Sender: TObject);
    procedure MenuInfoClick(Sender: TObject);
    procedure MenuReconnectClick(Sender: TObject);
    procedure MenuConnectClick(Sender: TObject);
    procedure MenuDisconnectClick(Sender: TObject);
    procedure MenuKeepAliveClick(Sender: TObject);

    // Timer
    procedure ProgressTimerTick(Sender: TObject);

    // Setters
    procedure SetBaseURL(const Value: string);
    procedure SetPopupMenu(Value: TPopupMenu);
    procedure SetActive(const Value: boolean);
    procedure SetMenuSections(const Value: TOllamaMenuSections);

    // Streaming pull used by background thread, holds the global SSL lock
    function PullModelStream(const AModelName: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean;
    // Applies pull progress from worker thread, must run on the main thread
    procedure UpdatePullProgress(const AModelName: string; APct: integer);
  protected
    procedure Loaded; override;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    // Public API
    // RefreshModels is asynchronous: it starts a background connection/refresh
    // and returns immediately; the result arrives via OnConnected or OnError.
    procedure RefreshModels;
    procedure PullModel(const ModelName: string);
    procedure DeleteModel(const ModelName: string);
    procedure StartModel(const ModelName: string);
    procedure StopModel(const ModelName: string);

    // Enable or disable the whole manager and start/stop connection attempts
    procedure Connect;
    procedure Disconnect;

    // Core API calls, return an empty string on failure and report via OnError
    function Generate(const ModelName, Prompt: string): string;
    function Chat(const ModelName, UserMessage: string): string;
    // Streaming chat with optional tools, returns the final JSON chunk or empty on error
    function ChatStream(const ModelName, MessagesJson, ToolsJson: string; AOnChunk: TOllamaStreamCallback;
      out AKind: TOllamaErrorKind; out AErrorMsg: string): string; overload;
    // Streaming chat with separate content and thinking callbacks
    function ChatStream(const ModelName, MessagesJson, ToolsJson: string; AOnContent, AOnThinking: TOllamaStreamCallback;
      out AKind: TOllamaErrorKind; out AErrorMsg: string): string; overload;
    // Non-streaming chat with tools, emits thinking and content once each
    function ChatWithTools(const ModelName, MessagesJson, ToolsJson: string; AOnContent, AOnThinking: TOllamaStreamCallback;
      out AKind: TOllamaErrorKind; out AErrorMsg: string): string; overload;
    // Non-streaming chat with tools, returns tool_calls only
    function ChatWithTools(const ModelName, MessagesJson, ToolsJson: string; out AKind: TOllamaErrorKind;
      out AErrorMsg: string): string; overload;

    // Synchronous model management, all return False on error and report via OnError
    // ShowModel returns raw JSON from /api/show for the given model
    function ShowModel(const ModelName: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): string;
    // GetVersion returns the Ollama server version as plain text
    function GetVersion(out Kind: TOllamaErrorKind; out ErrorMsg: string): string;
    // CopyModel duplicates a model under a new name
    function CopyModel(const Source, Destination: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean;
    // CreateModel builds a new model from a Modelfile content
    function CreateModel(const ModelName, ModelfileContent: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean;
    // LoadModelSync loads the model into memory and waits until ready
    function LoadModelSync(const ModelName: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean;
    // UnloadModelSync unloads the model from memory immediately
    function UnloadModelSync(const ModelName: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean;

    // Called by the background thread via Synchronize
    procedure BgFinished(AOp: TOllamaBgOp; const ModelName: string; Kind: TOllamaErrorKind; const ErrorMsg: string);
    procedure UnregisterThread(AThread: TThread);

    // Resets usage counters to zero
    procedure ResetUsage;
    // Returns context length of a loaded model from last refresh, 0 if unknown
    function GetModelContextLength(const ModelName: string): int64;
    // Returns cached /api/ps JSON for a running model, fetches on cache miss
    function GetRunningModelJson(const AModelName: string): string;
    // Quick TCP-only reachability check, no HTTP, no SSL, no locks
    function CheckServerReachableQuick(ATimeoutMs: integer = 500): boolean;

    property InstalledModels: TStringList read FInstalledModels;
    property RunningModels: TStringList read FRunningModels;
    property BaseURL: string read FBaseURL write SetBaseURL;
    property PopupMenu: TPopupMenu read FPopupMenu write SetPopupMenu;
    property Active: boolean read FActive write SetActive default True;
    property IsConnected: boolean read FConnected;
    property IsConnecting: boolean read FConnecting;
    property KeepAlive: integer read FKeepAlive write FKeepAlive default -1;
    property NumCtx: integer read FNumCtx write FNumCtx default 0;
    property LastPromptEvalCount: integer read FLastPromptEvalCount;
    property LastEvalCount: integer read FLastEvalCount;
    property LastUsageTotal: integer read GetLastUsageTotal;
    property LastRequestStats: string read FLastRequestStats;
    property AutoRefresh: boolean read FAutoRefresh write FAutoRefresh default True;
    property ConnectionTimeout: integer read FConnectionTimeout write FConnectionTimeout default 5000;
    property RequestTimeout: integer read FRequestTimeout write FRequestTimeout default 30000;
    property PullTimeout: integer read FPullTimeout write FPullTimeout default 0;
    property MenuSections: TOllamaMenuSections read FMenuSections write SetMenuSections default
      [msPull, msKeepAlive, msServer, msModels, msConnect];
    property MonitorModelState: boolean read FMonitorModelState write SetMonitorModelState default False;
    property MonitorInterval: integer read FMonitorInterval write SetMonitorInterval default 2000;
    property OnModelsRefreshed: TModelsRefreshedEvent read FOnModelsRefreshed write FOnModelsRefreshed;
    property OnError: TOllamaErrorEvent read FOnError write FOnError;
    property OnPullProgress: TPullProgressEvent read FOnPullProgress write FOnPullProgress;
    property OnConnecting: TConnectingEvent read FOnConnecting write FOnConnecting;
    property OnConnected: TConnectedEvent read FOnConnected write FOnConnected;
    property OnModelStart: TModelOperationEvent read FOnModelStart write FOnModelStart;
    property OnModelStop: TModelOperationEvent read FOnModelStop write FOnModelStop;
  end;

  { TOllamaManager }

  TOllamaManager = class(TCustomOllamaManager)
  published
    // Base address of the Ollama server, e.g. http://localhost:11434
    property BaseURL;
    // Popup menu that receives the model management items; may be nil
    property PopupMenu;
    // keep_alive value sent with start requests; -1 means no time limit
    property KeepAlive;
    // num_ctx value sent with requests, 0 means use Ollama default
    property NumCtx;
    // Master switch; when False no connection attempts are made and the menu is empty
    property Active;
    // When True, the model list is refreshed before each menu popup
    property AutoRefresh;
    // Connection timeout in milliseconds, applied while establishing the connection
    property ConnectionTimeout;
    // Maximum time in milliseconds to wait for a model start or stop operation.
    property ModelTimeout: integer read FModelTimeout write FModelTimeout default 300000;
    // Timeout in milliseconds for regular API requests
    property RequestTimeout;
    // Per-chunk timeout in milliseconds during pull, 0 means use RequestTimeout
    property PullTimeout;
    // Sections of the popup menu shown to the user; clear a flag to hide it
    property MenuSections;
    // Fired for any API or connection error; never raises
    property OnError;
    // Fired when pull progress changes (currently only start and finish)
    property OnPullProgress;
    // Fired before a background connection or refresh attempt begins
    property OnConnecting;
    // Fired after the model list has been successfully refreshed
    property OnConnected;
    // Enables periodic monitoring of running model state
    property MonitorModelState;
    // Polling interval in milliseconds
    property MonitorInterval;
    // Fired after the installed model list has been refreshed
    property OnModelsRefreshed;
    // Occurs when a model start operation completes.
    property OnModelStart;
    // Occurs when a model stop operation completes.
    property OnModelStop;
  end;

implementation

resourcestring
  rsPullModelMenu = 'Pull model...';
  rsServerMenu = 'Server...';
  rsStartMenu = 'Start';
  rsStopMenu = 'Stop';
  rsDeleteMenu = 'Delete';
  rsCopyNameMenu = 'Copy Name';
  rsInfoMenu = 'Info...';
  rsLoadingModel = 'Loading %s...';
  rsLoadingModelPercent = 'Loading %s... %d%%';
  rsStartingPercent = 'Starting... %d%%';
  rsDeleteConfirm = 'Delete model "%s"?';
  rsPullCaption = 'Pull Ollama model';
  rsPullPrompt = 'Model name (e.g. llama3.2):';
  rsServerCaption = 'Ollama server';
  rsServerPrompt = 'Server URL (e.g. http://localhost:11434):';
  rsInfoMetadataError = 'Error fetching metadata: %s';
  rsInfoRunningHeader = '--- Running ---';
  rsInfoStatusLoaded = 'loaded';
  rsInfoStatusNotLoaded = 'not loaded';
  rsInfoFormat = 'Format: %s';
  rsInfoFamily = 'Family: %s';
  rsInfoParameters = 'Parameters: %s';
  rsInfoQuantization = 'Quantization: %s';
  rsInfoModified = 'Modified: %s';
  rsInfoTotalMemory = 'Total memory: %s';
  rsInfoVram = 'VRAM: %s (%d%% GPU)';
  rsInfoContextLength = 'Context length: %d';
  rsInfoUnloadsAt = 'Unloads at: %s';
  rsInfoStatus = 'Status: %s';
  rsInfoCloudModel = '(cloud model)';
  rsHttpError = 'HTTP %d: %s';
  rsConnectionError = 'Connection error';
  rsConnectingStatus = 'Connecting...';
  rsDisconnectedStatus = 'Server unavailable (click to retry)';
  rsConnectMenu = 'Connect';
  rsDisconnectMenu = 'Disconnect';
  rsInfoModelSize = 'Model size: %s';
  rsKeepAliveMenu = 'Keep Alive';
  rsKeepAliveForever = 'Forever';
  rsKeepAlive1Hour = '1 hour';
  rsKeepAlive2Hours = '2 hours';
  rsKeepAlive3Hours = '3 hours';

const
  TAG_PULL = 1;
  TAG_MODEL = 2;
  TAG_LOADING = 3;
  TAG_SEPARATOR = 4;
  TAG_CONNECTION = 5;
  TAG_SERVER = 6;
  TAG_KEEPALIVE = 7;
  MONITOR_RETRY_INTERVAL = 15000;

function BytesToHuman(const B: int64): string;
begin
  if B >= int64(1024) * 1024 * 1024 then
    Result := FormatFloat('0.00', B / (1024.0 * 1024 * 1024)) + ' GB'
  else if B >= 1024 * 1024 then
    Result := FormatFloat('0.00', B / (1024.0 * 1024)) + ' MB'
  else if B >= 1024 then
    Result := FormatFloat('0.00', B / 1024.0) + ' KB'
  else
    Result := IntToStr(B) + ' B';
end;

function ClassifyHttp(const Code: integer): TOllamaErrorKind;
begin
  if Code = 404 then
    Result := oekNotFound
  else if (Code >= 400) and (Code < 500) then
    Result := oekHttpClient
  else if (Code >= 500) and (Code < 600) then
    Result := oekHttpServer
  else
    Result := oekUnknown;
end;

procedure Register;
begin
  RegisterComponents('Ollama', [TOllamaManager]);
end;

{ TPullProgressCall }

procedure TPullProgressCall.Fire;
begin
  try
    if Assigned(Manager) then
      Manager.UpdatePullProgress(ModelName, Pct);
  finally
    Free;
  end;
end;

{ TPullStreamHelper }

procedure TPullStreamHelper.HandleRaw(const AChunk: string; var ACancel: boolean);
var
  P: integer;
  OneLine: string;
  Data: TJSONData;
  Obj: TJSONObject;
  Status: string;
  Completed, Total: int64;
  Pct: integer;
  Call: TPullProgressCall;
begin
  // Abort pull when the manager is shutting down
  if Assigned(Manager) and Manager.FShutdown then
  begin
    ACancel := True;
    Exit;
  end;
  Buffer := Buffer + AChunk;
  P := Pos(#10, Buffer);
  while P > 0 do
  begin
    OneLine := Trim(Copy(Buffer, 1, P - 1));
    Buffer := Copy(Buffer, P + 1, MaxInt);
    if OneLine <> '' then
    begin
      Data := nil;
      try
        try
          Data := GetJSON(OneLine);
        except
          Data := nil;
        end;
        if (Data <> nil) and (Data.JSONType = jtObject) then
        begin
          Obj := TJSONObject(Data);
          Status := Obj.Get('status', '');
          if Status = 'success' then
          begin
            Done := True;
            ACancel := True;
          end
          else
          begin
            Completed := Obj.Get('completed', int64(0));
            Total := Obj.Get('total', int64(0));
            if Total > 0 then
            begin
              Pct := Round(Completed * 100 / Total);
              if Pct <> LastPct then
              begin
                LastPct := Pct;
                Call := TPullProgressCall.Create;
                Call.Manager := Manager;
                Call.ModelName := ModelName;
                Call.Pct := Pct;
                TThread.Queue(nil, @Call.Fire);
              end;
            end;
          end;
        end;
      finally
        Data.Free;
      end;
    end;
    if ACancel then
      Break;
    P := Pos(#10, Buffer);
  end;
end;

{ TOllamaBgThread }

constructor TOllamaBgThread.Create(AManager: TCustomOllamaManager; AOp: TOllamaBgOp; const AModelName: string; AGen: integer = 0);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FManager := AManager;
  FOp := AOp;
  FModelName := AModelName;
  FGen := AGen;
  FErrorKind := oekNone;
  FErrorMsg := '';
  FTagsJson := '';
  FPsJson := '';
  if Assigned(FManager) and Assigned(FManager.FActiveThreads) then
    FManager.FActiveThreads.Add(Self);
  Start;
end;

procedure TOllamaBgThread.Execute;
var
  JsonBody: string;
begin
  try
    if Assigned(FManager) then
    begin
      case FOp of
        boPull:
        begin
          // Streaming pull: parse progress from each chunk, no 30 s timeout
          FManager.PullModelStream(FModelName, FErrorKind, FErrorMsg);
        end;
        boStart:
        begin
          JsonBody := Format('{"model":"%s","prompt":"","keep_alive":%d,"stream":false}', [FModelName, FManager.KeepAlive]);
          FManager.ApiPost('/api/generate', JsonBody, FErrorKind, FErrorMsg, FManager.FModelTimeout);
        end;
        boStop:
        begin
          JsonBody := Format('{"model":"%s","prompt":"","keep_alive":0,"stream":false}', [FModelName]);
          FManager.ApiPost('/api/generate', JsonBody, FErrorKind, FErrorMsg, FManager.FModelTimeout);
        end;
        boRefresh:
        begin
          FTagsJson := FManager.ApiGet('/api/tags', FErrorKind, FErrorMsg);
          if FErrorKind = oekNone then
            FPsJson := FManager.ApiGet('/api/ps', FErrorKind, FErrorMsg);
        end;
        else
          ;
      end;
    end;
  finally
    if Assigned(FManager) then
    begin
      try
        Synchronize(@DoFinish);
      except
        ; // Ignore - cannot reach the main thread during shutdown
      end;
    end;
  end;
end;

procedure TOllamaBgThread.DoFinish;
var
  Mgr: TCustomOllamaManager;
begin
  Mgr := FManager;
  if not Assigned(Mgr) then
    Exit;
  Mgr.UnregisterThread(Self);
  if FOp = boRefresh then
    Mgr.ProcessRefreshData(FTagsJson, FPsJson, FErrorKind, FErrorMsg, FGen)
  else
    Mgr.BgFinished(FOp, FModelName, FErrorKind, FErrorMsg);
end;

{ TCustomOllamaManager }

constructor TCustomOllamaManager.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FBaseURL := 'http://localhost:11434';
  FKeepAlive := -1;
  FNumCtx := 0;
  FLastPromptEvalCount := 0;
  FLastEvalCount := 0;
  FLastRequestStats := string.Empty;
  FAutoRefresh := True;
  FConnectionTimeout := 5000;
  FRequestTimeout := 30000;
  FModelTimeout := 300000;
  FPullTimeout := 0;
  FMenuSections := [msPull, msKeepAlive, msServer, msModels, msConnect];
  FConnecting := False;
  FConnected := False;
  FModelsInitialized := False;
  FActive := True;
  FConnectGen := 0;
  FShutdown := False;
  FLastPopupTick := 0;
  FWasConnectedAtPopup := False;

  FInstalledModels := TStringList.Create;
  FInstalledDetails := TStringList.Create;
  FRunningModels := TStringList.Create;
  FRunningDetails := TStringList.Create;

  FInstalledDetails.NameValueSeparator := '=';
  FLoadingModels := TStringList.Create;
  FStartingModels := TStringList.Create;
  FStartingProgress := TStringList.Create;
  FPullProgress := TStringList.Create;
  FStartSubItems := TStringList.Create;
  FLoadingSubItems := TStringList.Create;
  FActiveThreads := TList.Create;

  FInstalledModels.Sorted := True;
  FInstalledModels.Duplicates := dupIgnore;
  FRunningModels.Sorted := True;
  FRunningModels.Duplicates := dupIgnore;
  FLoadingModels.Sorted := True;
  FLoadingModels.Duplicates := dupIgnore;

  FRunningDetails.NameValueSeparator := '=';
  FStartingProgress.NameValueSeparator := '=';
  FPullProgress.NameValueSeparator := '=';

  FProgressTimer := TTimer.Create(nil);
  FProgressTimer.Interval := 300;
  FProgressTimer.Enabled := False;
  FProgressTimer.OnTimer := @ProgressTimerTick;

  FMonitorModelState := False;
  FMonitorInterval := 2000;
  FMonitorInitialized := False;
  FInternalModelChanges := TStringList.Create;
  FInternalModelChanges.NameValueSeparator := '=';

  FMonitorTimer := TTimer.Create(nil);
  FMonitorTimer.Enabled := False;
  FMonitorTimer.Interval := FMonitorInterval;
  FMonitorTimer.OnTimer := @MonitorTimerTick;
end;

destructor TCustomOllamaManager.Destroy;
var
  I: integer;
begin
  FShutdown := True;

  if Assigned(FProgressTimer) then
  begin
    FProgressTimer.Enabled := False;
    FreeAndNil(FProgressTimer);
  end;

  for I := FActiveThreads.Count - 1 downto 0 do
    TThread(FActiveThreads[I]).Terminate;

  while FActiveThreads.Count > 0 do
    CheckSynchronize(100);

  FActiveThreads.Free;
  FreeAndNil(FInstalledModels);
  FreeAndNil(FInstalledDetails);
  FreeAndNil(FRunningModels);
  FreeAndNil(FRunningDetails);
  FreeAndNil(FLoadingModels);
  FreeAndNil(FStartingModels);
  FreeAndNil(FStartingProgress);
  FreeAndNil(FPullProgress);
  FreeAndNil(FStartSubItems);
  FreeAndNil(FLoadingSubItems);
  FreeAndNil(FMonitorTimer);
  FreeAndNil(FInternalModelChanges);
  inherited Destroy;
end;

function TCustomOllamaManager.GetLastUsageTotal: integer;
begin
  Result := FLastPromptEvalCount + FLastEvalCount;
end;

function TCustomOllamaManager.BuildOptionsJson: string;
begin
  if FNumCtx > 0 then
    Result := Format(',"options":{"num_ctx":%d}', [FNumCtx])
  else
    Result := '';
end;

procedure TCustomOllamaManager.ResetUsage;
begin
  FLastPromptEvalCount := 0;
  FLastEvalCount := 0;
end;

procedure TCustomOllamaManager.UpdatePullProgress(const AModelName: string; APct: integer);
var
  Idx: integer;
  SubItem: TMenuItem;
begin
  if FShutdown then
    Exit;
  Idx := FPullProgress.IndexOfName(AModelName);
  if Idx >= 0 then
    FPullProgress.Values[AModelName] := IntToStr(APct)
  else
    FPullProgress.Add(AModelName + '=' + IntToStr(APct));
  // Update menu item caption in place, no full rebuild needed
  Idx := FLoadingSubItems.IndexOf(AModelName);
  if Idx >= 0 then
  begin
    SubItem := TMenuItem(FLoadingSubItems.Objects[Idx]);
    if Assigned(SubItem) then
      SubItem.Caption := Format(rsLoadingModelPercent, [AModelName, APct]);
  end;
  if Assigned(FOnPullProgress) then
  try
    FOnPullProgress(Self, AModelName, APct);
  except
    ; // Ignore user handler exceptions
  end;
end;

function TCustomOllamaManager.PullModelStream(const AModelName: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean;
var
  JsonBody, Url, ErrFromNetwork: string;
  Tm: TTimeout;
  Helper: TPullStreamHelper;
begin
  Result := False;
  Kind := oekNone;
  ErrorMsg := '';
  if FShutdown then
  begin
    Kind := oekCancelled;
    ErrorMsg := 'Cancelled';
    Exit;
  end;
  JsonBody := Format('{"name":"%s","stream":true}', [AModelName.EscapeText]);
  // Pull can take a long time, but each individual recv is bounded by the
  // per-chunk timeout. PullTimeout overrides the request timeout when set.
  if FPullTimeout > 0 then
    Tm.Request := FPullTimeout
  else
    Tm.Request := FRequestTimeout;
  Tm.Connection := FConnectionTimeout;
  Url := FBaseURL + '/api/pull';
  Helper := TPullStreamHelper.Create;
  try
    Helper.Manager := Self;
    Helper.ModelName := AModelName;
    Helper.Buffer := '';
    Helper.Done := False;
    Helper.LastPct := -1;
    ErrFromNetwork := '';
    // WebStreamRequest holds the global SSL lock, other HTTP calls block until pull ends
    if not TNetwork.WebStreamRequest(wmPost, Url, JsonBody, nil, 'OllamaManager/1.0', 'application/json',
      'application/json', Tm, @Helper.HandleRaw, ErrFromNetwork) then
    begin
      Kind := oekConnection;
      ErrorMsg := ErrFromNetwork;
      Exit;
    end;
    if Helper.Done then
      Result := True
    else
    begin
      Kind := oekConnection;
      ErrorMsg := 'Pull interrupted before completion';
    end;
  finally
    Helper.Free;
  end;
end;

function TCustomOllamaManager.GetModelContextLength(const ModelName: string): int64;
var
  Idx: integer;
  PsJson: string;
  PsData, ModelsData, Item: TJSONData;
  Arr: TJSONArray;
  Obj: TJSONObject;

  ItemName: string;
  Kind: TOllamaErrorKind;
  ErrMsg: string;

// Extracts context_length of one model from /api/ps JSON array
  function ParseFromPs(const AJson: string): int64;
  var
    I: integer;
  begin
    Result := 0;
    ModelsData := nil;
    try
      try
        ModelsData := GetJSON(AJson);
        if (ModelsData = nil) or (ModelsData.JSONType <> jtObject) then
          Exit;
        Arr := TJSONObject(ModelsData).Arrays['models'];
        if not Assigned(Arr) then
          Exit;
        for I := 0 to Arr.Count - 1 do
        begin
          Obj := Arr.Objects[I];
          ItemName := Obj.Get('name', '');
          if ItemName = '' then
            ItemName := Obj.Get('model', '');
          if ItemName = ModelName then
          begin
            Item := Obj.Find('context_length');
            if Item <> nil then
              Result := Item.AsInt64;
            Exit;
          end;
        end;
      except
        Result := 0;
      end;
    finally
      ModelsData.Free;
    end;
  end;

begin
  Result := 0;
  // Fast path: use cached running details from last refresh
  if Assigned(FRunningDetails) then
  begin
    Idx := FRunningDetails.IndexOfName(ModelName);
    if Idx >= 0 then
    begin
      PsJson := FRunningDetails.ValueFromIndex[Idx];
      PsData := nil;
      try
        try
          PsData := GetJSON(PsJson);
          if (PsData <> nil) and (PsData.JSONType = jtObject) then
            Result := TJSONObject(PsData).Get('context_length', int64(0));
        except
          Result := 0;
        end;
      finally
        PsData.Free;
      end;
      if Result > 0 then
        Exit;
    end;
  end;
  // Slow path: query /api/ps synchronously when cache miss
  if FShutdown then
    Exit;
  PsJson := ApiGet('/api/ps', Kind, ErrMsg);
  if Kind <> oekNone then
    Exit;
  Result := ParseFromPs(PsJson);
  // Cache for next callers
  if (Result > 0) and Assigned(FRunningDetails) then
    FRunningDetails.Values[ModelName] := '{"context_length":' + IntToStr(Result) + '}';
end;

function TCustomOllamaManager.GetRunningModelJson(const AModelName: string): string;
var
  Idx: integer;
  PsJson: string;
  Kind: TOllamaErrorKind;
  ErrMsg: string;
begin
  Result := '';
  // Fast path: cached details from the last refresh
  if Assigned(FRunningDetails) then
  begin
    Idx := FRunningDetails.IndexOfName(AModelName);
    if Idx >= 0 then
      Exit(FRunningDetails.ValueFromIndex[Idx]);
  end;
  // Slow path: query /api/ps synchronously and cache the result
  if FShutdown then
    Exit;
  PsJson := ApiGet('/api/ps', Kind, ErrMsg);
  if Kind <> oekNone then
    Exit;
  ParseModels(PsJson, FRunningDetails);
  Idx := FRunningDetails.IndexOfName(AModelName);
  if Idx >= 0 then
    Result := FRunningDetails.ValueFromIndex[Idx];
end;

function TCustomOllamaManager.CheckServerReachableQuick(ATimeoutMs: integer): boolean;
var
  Sock: TTCPBlockSocket;
  U, Scheme, Host: string;
  Port, P: integer;
begin
  Result := False;
  if Trim(FBaseURL) = '' then
    Exit;
  // Parse host and port from BaseURL without any HTTP library
  U := Trim(FBaseURL);
  Scheme := LowerCase(Copy(U, 1, 8));
  if Pos('https://', Scheme) = 1 then
  begin
    U := Copy(U, 9, MaxInt);
    Port := 443;
  end
  else if Pos('http://', Scheme) = 1 then
  begin
    U := Copy(U, 8, MaxInt);
    Port := 80;
  end
  else
    Exit;
  // Cut path, query and fragment
  P := 1;
  while (P <= Length(U)) and not (U[P] in ['/', '?', '#']) do
    Inc(P);
  if P <= Length(U) then
    U := Copy(U, 1, P - 1);
  // Split host:port
  P := Pos(':', U);
  if P > 0 then
  begin
    Host := Copy(U, 1, P - 1);
    Port := StrToIntDef(Copy(U, P + 1, MaxInt), Port);
  end
  else
    Host := U;
  if Host = '' then
    Exit;
  Sock := TTCPBlockSocket.Create;
  try
    Sock.ConnectionTimeout := ATimeoutMs;
    try
      Sock.Connect(Host, IntToStr(Port));
      Result := Sock.LastError = 0;
    except
      Result := False;
    end;
  finally
    Sock.Free;
  end;
end;

procedure TCustomOllamaManager.DoError(Kind: TOllamaErrorKind; const ModelName, Msg: string);
begin
  if Kind = oekNone then
    Exit;
  if not Assigned(FOnError) then
    Exit;
  try
    FOnError(Self, Kind, ModelName, Msg);
  except
    ; // User handler raised an exception; ignore so the manager stays consistent
  end;
end;

procedure TCustomOllamaManager.UnregisterThread(AThread: TThread);
var
  Idx: integer;
begin
  if Assigned(FActiveThreads) then
  begin
    Idx := FActiveThreads.IndexOf(AThread);
    if Idx >= 0 then
      FActiveThreads.Delete(Idx);
  end;
end;

procedure TCustomOllamaManager.BeginConnect;
begin
  if FShutdown then
    Exit;
  if csDesigning in ComponentState then
    Exit;
  if not FActive then
    Exit;
  if FConnecting then
    Exit;

  // FConnected is not reset here: while a background refresh runs, the
  // existing model list remains visible; the flag changes in ProcessRefreshData.
  Inc(FConnectGen);
  FConnecting := True;

  if Assigned(FOnConnecting) then
  try
    FOnConnecting(Self);
  except
    ; // Ignore user handler exceptions
  end;

  TOllamaBgThread.Create(Self, boRefresh, '', FConnectGen);
end;

procedure TCustomOllamaManager.ProcessModelStateChanges(const OldModels, NewModels: TStringList);
var
  I, Idx: integer;
  ModelName: string;
begin
  if not FMonitorModelState then
    Exit;

  // First refresh establishes the baseline without emitting events
  if not FMonitorInitialized then
  begin
    FMonitorInitialized := True;
    Exit;
  end;

  // Detect newly running models
  for I := 0 to NewModels.Count - 1 do
  begin
    ModelName := NewModels[I];
    if OldModels.IndexOf(ModelName) < 0 then
    begin
      // Internal operations already report their own completion event
      Idx := FInternalModelChanges.IndexOfName(ModelName);
      if Idx >= 0 then
      begin
        FInternalModelChanges.Delete(Idx);
        Continue;
      end;

      if Assigned(FOnModelStart) then
      try
        FOnModelStart(Self, ModelName, True, True, string.Empty);
      except
        ; // Ignore user handler exceptions
      end;
    end;
  end;

  // Detect unloaded models
  for I := 0 to OldModels.Count - 1 do
  begin
    ModelName := OldModels[I];
    if NewModels.IndexOf(ModelName) < 0 then
    begin
      // Internal operations already report their own completion event
      Idx := FInternalModelChanges.IndexOfName(ModelName);
      if Idx >= 0 then
      begin
        FInternalModelChanges.Delete(Idx);
        Continue;
      end;

      if Assigned(FOnModelStop) then
      try
        FOnModelStop(Self, ModelName, True, True, string.Empty);
      except
        ; // Ignore user handler exceptions
      end;
    end;
  end;
end;

procedure TCustomOllamaManager.ProcessRefreshData(const TagsJson, PsJson: string; Kind: TOllamaErrorKind;
  const ErrorMsg: string; AGen: integer);
var
  NewInstalled, NewRunning: TStringList;
  OldInstalled, OldRunning: TStringList;
  ModelsChanged: boolean;
  I: integer;
begin
  if FShutdown then
    Exit;

  // Ignore results from a stale attempt (e.g. after Disconnect or a newer BeginConnect)
  if AGen <> FConnectGen then
    Exit;

  FConnecting := False;

  if Kind <> oekNone then
  begin
    FConnected := False;
    FMonitorInitialized := False;

    // Retry connection less frequently while the server is unavailable
    if Assigned(FMonitorTimer) and FMonitorModelState and FActive then
      FMonitorTimer.Interval := MONITOR_RETRY_INTERVAL;

    DoError(Kind, '', ErrorMsg);
    if Assigned(FPopupMenu) then
      BuildPopupMenu;
    Exit;
  end;

  // Invalid responses must not be interpreted as an empty model list
  if not ValidateModelsJson(TagsJson) or not ValidateModelsJson(PsJson) then
  begin
    FConnected := False;
    FMonitorInitialized := False;

    if Assigned(FMonitorTimer) and FMonitorModelState and FActive then
      FMonitorTimer.Interval := MONITOR_RETRY_INTERVAL;

    DoError(oekJson, '', 'Invalid model list response from Ollama');
    if Assigned(FPopupMenu) then
      BuildPopupMenu;
    Exit;
  end;

  NewInstalled := nil;
  NewRunning := nil;
  OldInstalled := TStringList.Create;
  OldRunning := TStringList.Create;
  ModelsChanged := False;

  try
    OldInstalled.Assign(FInstalledModels);
    OldRunning.Assign(FRunningModels);

    try
      NewInstalled := ParseModels(TagsJson, FInstalledDetails);
      NewRunning := ParseModels(PsJson, FRunningDetails);

      ModelsChanged := (FInstalledModels.Count <> NewInstalled.Count) or (FRunningModels.Count <> NewRunning.Count);

      if not ModelsChanged then
        for I := 0 to NewInstalled.Count - 1 do
          if FInstalledModels[I] <> NewInstalled[I] then
          begin
            ModelsChanged := True;
            Break;
          end;

      if not ModelsChanged then
        for I := 0 to NewRunning.Count - 1 do
          if FRunningModels[I] <> NewRunning[I] then
          begin
            ModelsChanged := True;
            Break;
          end;

      // Detect running state changes before replacing the old lists
      ProcessModelStateChanges(OldRunning, NewRunning);

      FInstalledModels.Assign(NewInstalled);
      FRunningModels.Assign(NewRunning);
      FConnected := True;

      // Remove completed operation markers that produced no state change
      for I := FInternalModelChanges.Count - 1 downto 0 do
        if (FInternalModelChanges.ValueFromIndex[I] = 'StartDone') or (FInternalModelChanges.ValueFromIndex[I] = 'StopDone') then
          FInternalModelChanges.Delete(I);

      // Restore the normal polling interval after a successful connection
      if Assigned(FMonitorTimer) and FMonitorModelState then
        FMonitorTimer.Interval := FMonitorInterval;

      if Assigned(FOnConnected) then
      try
        FOnConnected(Self);
      except
        ; // Ignore user handler exceptions
      end;

      // Skip the initial model list because it establishes the baseline
      if FModelsInitialized and Assigned(FOnModelsRefreshed) then
      try
        FOnModelsRefreshed(Self, OldInstalled, FInstalledModels);
      except
        ; // Ignore user handler exceptions
      end;

      FModelsInitialized := True;
    except
      // Defensive - should not normally happen
      FConnected := False;
      FMonitorInitialized := False;
    end;
  finally
    NewInstalled.Free;
    NewRunning.Free;
    OldInstalled.Free;
    OldRunning.Free;
  end;

  // Rebuild the popup only when the connection state or model lists change
  if Assigned(FPopupMenu) and ((FConnected <> FWasConnectedAtPopup) or ModelsChanged) then
    BuildPopupMenu;
end;

procedure TCustomOllamaManager.BgFinished(AOp: TOllamaBgOp; const ModelName: string; Kind: TOllamaErrorKind; const ErrorMsg: string);
var
  Idx: integer;
  Success: boolean;
begin
  if FShutdown then
    Exit;

  Idx := FLoadingModels.IndexOf(ModelName);
  if Idx >= 0 then
    FLoadingModels.Delete(Idx);

  Idx := FPullProgress.IndexOfName(ModelName);
  if Idx >= 0 then
    FPullProgress.Delete(Idx);

  Idx := FStartingModels.IndexOf(ModelName);
  if Idx >= 0 then
    FStartingModels.Delete(Idx);

  Idx := FStartingProgress.IndexOfName(ModelName);
  if Idx >= 0 then
    FStartingProgress.Delete(Idx);

  Success := Kind = oekNone;

  // Keep successful operation markers until the next state refresh
  Idx := FInternalModelChanges.IndexOfName(ModelName);
  if Idx >= 0 then
  begin
    if Success then
    begin
      if AOp = boStart then
        FInternalModelChanges.ValueFromIndex[Idx] := 'StartDone'
      else if AOp = boStop then
        FInternalModelChanges.ValueFromIndex[Idx] := 'StopDone';
    end
    else
      FInternalModelChanges.Delete(Idx);
  end;

  if Kind <> oekNone then
    DoError(Kind, ModelName, ErrorMsg);

  case AOp of
    boStart:
      if Assigned(FOnModelStart) then
      try
        FOnModelStart(Self, ModelName, False, Success, ErrorMsg);
      except
        ; // Ignore user handler exceptions
      end;
    boStop:
      if Assigned(FOnModelStop) then
      try
        FOnModelStop(Self, ModelName, False, Success, ErrorMsg);
      except
        ; // Ignore user handler exceptions
      end;
    else
      ;
  end;

  BeginConnect;

  if (FStartingModels.Count = 0) and Assigned(FProgressTimer) then
    FProgressTimer.Enabled := False;
end;

procedure TCustomOllamaManager.Loaded;
begin
  inherited Loaded;
  // Remove stale items streamed from a previous design-time build; only
  // relevant in the IDE so the .lfm is not polluted on the next save
  if (csDesigning in ComponentState) and Assigned(FPopupMenu) then
  begin
    ClearPopupMenu;
    Exit;
  end;
  // Kick off the initial refresh so RunningDetails is populated for the agent
  if FActive then
    BeginConnect;
end;

procedure TCustomOllamaManager.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FPopupMenu) then
    SetPopupMenu(nil);
end;

procedure TCustomOllamaManager.SetBaseURL(const Value: string);
var
  NewURL: string;
begin
  NewURL := TrimRight(Value);
  while NewURL.EndsWith('/') do
    NewURL := NewURL.Substring(0, NewURL.Length - 1);
  if NewURL = FBaseURL then
    Exit;
  FBaseURL := NewURL;
  FConnected := False;
  FModelsInitialized := False;
  FMonitorInitialized := False;
  FRunningModels.Clear;
  FRunningDetails.Clear;
  FInternalModelChanges.Clear;

  // Invalidate any in-flight connection to the previous address so that
  // its result is ignored and the next attempt targets the new address
  Inc(FConnectGen);
  FConnecting := False;

  if Assigned(FMonitorTimer) and FMonitorModelState and FActive then
    FMonitorTimer.Interval := MONITOR_RETRY_INTERVAL;

  if Assigned(FPopupMenu) and FAutoRefresh then
    BeginConnect;
end;

procedure TCustomOllamaManager.SetPopupMenu(Value: TPopupMenu);
begin
  if FPopupMenu = Value then
    Exit;

  FStartSubItems.Clear;
  FLoadingSubItems.Clear;

  if Assigned(FPopupMenu) then
  begin
    if Assigned(FPrevPopupHandler) then
      FPopupMenu.OnPopup := FPrevPopupHandler
    else
      FPopupMenu.OnPopup := nil;
    FPopupMenu.RemoveFreeNotification(Self);
  end;

  FPopupMenu := Value;

  if Assigned(FPopupMenu) then
  begin
    FPopupMenu.FreeNotification(Self);
    FPrevPopupHandler := FPopupMenu.OnPopup;
    FPopupMenu.OnPopup := @DoPopup;
    if AutoRefresh then
      BeginConnect;
  end;
end;

procedure TCustomOllamaManager.SetActive(const Value: boolean);
begin
  if FActive = Value then
    Exit;
  FActive := Value;

  if Assigned(FMonitorTimer) then
    FMonitorTimer.Enabled := Value and FMonitorModelState;

  if Value then
    BeginConnect
  else
  begin
    // Invalidate any pending background result and drop connection state
    Inc(FConnectGen);
    FConnecting := False;
    FConnected := False;
    FMonitorInitialized := False;
    if Assigned(FPopupMenu) then
      BuildPopupMenu;
  end;
end;

procedure TCustomOllamaManager.SetMenuSections(const Value: TOllamaMenuSections);
begin
  if FMenuSections = Value then
    Exit;
  FMenuSections := Value;
  if Assigned(FPopupMenu) then
    BuildPopupMenu;
end;

procedure TCustomOllamaManager.Connect;
begin
  SetActive(True);
end;

procedure TCustomOllamaManager.Disconnect;
begin
  SetActive(False);
end;

procedure TCustomOllamaManager.DoPopup(Sender: TObject);
begin
  FLastPopupTick := GetTickCount64;
  FWasConnectedAtPopup := FConnected;
  if FActive and FAutoRefresh and not FConnecting then
    BeginConnect;
  BuildPopupMenu;
end;

procedure TCustomOllamaManager.ClearPopupMenu;
var
  I: integer;
  Item: TMenuItem;
begin
  if not Assigned(FPopupMenu) then
    Exit;

  FStartSubItems.Clear;
  FLoadingSubItems.Clear;

  for I := FPopupMenu.Items.Count - 1 downto 0 do
  begin
    Item := FPopupMenu.Items[I];
    if (Item.Tag = TAG_PULL) or (Item.Tag = TAG_SERVER) or (Item.Tag = TAG_MODEL) or (Item.Tag = TAG_LOADING) or
      (Item.Tag = TAG_SEPARATOR) or (Item.Tag = TAG_CONNECTION) or (Item.Tag = TAG_KEEPALIVE) then
      FPopupMenu.Items.Delete(I);
  end;
end;

procedure TCustomOllamaManager.BuildPopupMenu;
var
  I, Pct, InsertPos, ProgIdx: integer;
  ModelItem, SubItem: TMenuItem;
  ModelName: string;
  IsRunning, IsStarting: boolean;
  HasContentAbove: boolean;
  HasModels: boolean;
begin
  if not Assigned(FPopupMenu) then
    Exit;
  if csDesigning in ComponentState then
    Exit;

  ClearPopupMenu;

  InsertPos := 0;
  HasContentAbove := False;

  // Content block is shown only while the manager is active
  if FActive then
  begin
    // Pull item is available only after a successful connection
    if FConnected and (msPull in FMenuSections) then
    begin
      ModelItem := TMenuItem.Create(FPopupMenu);
      ModelItem.Caption := rsPullModelMenu;
      ModelItem.Tag := TAG_PULL;
      ModelItem.OnClick := @MenuPullClick;
      FPopupMenu.Items.Insert(InsertPos, ModelItem);
      Inc(InsertPos);
      HasContentAbove := True;
    end;

    // Keep Alive settings
    if FConnected and (msKeepAlive in FMenuSections) then
    begin
      ModelItem := TMenuItem.Create(FPopupMenu);
      ModelItem.Caption := rsKeepAliveMenu;
      ModelItem.Tag := TAG_KEEPALIVE;
      FPopupMenu.Items.Insert(InsertPos, ModelItem);
      Inc(InsertPos);

      SubItem := TMenuItem.Create(ModelItem);
      SubItem.Caption := rsKeepAliveForever;
      SubItem.Tag := -1;
      SubItem.Checked := FKeepAlive = -1;
      SubItem.OnClick := @MenuKeepAliveClick;
      ModelItem.Add(SubItem);

      SubItem := TMenuItem.Create(ModelItem);
      SubItem.Caption := rsKeepAlive1Hour;
      SubItem.Tag := 3600;
      SubItem.Checked := FKeepAlive = 3600;
      SubItem.OnClick := @MenuKeepAliveClick;
      ModelItem.Add(SubItem);

      SubItem := TMenuItem.Create(ModelItem);
      SubItem.Caption := rsKeepAlive2Hours;
      SubItem.Tag := 7200;
      SubItem.Checked := FKeepAlive = 7200;
      SubItem.OnClick := @MenuKeepAliveClick;
      ModelItem.Add(SubItem);

      SubItem := TMenuItem.Create(ModelItem);
      SubItem.Caption := rsKeepAlive3Hours;
      SubItem.Tag := 10800;
      SubItem.Checked := FKeepAlive = 10800;
      SubItem.OnClick := @MenuKeepAliveClick;
      ModelItem.Add(SubItem);
    end;

    if FConnected then
    begin
      if msModels in FMenuSections then
      begin
        HasModels := (FInstalledModels.Count > 0) or (FLoadingModels.Count > 0);

        // Separator between the Pull item and the model list
        if HasContentAbove and HasModels then
        begin
          ModelItem := TMenuItem.Create(FPopupMenu);
          ModelItem.Caption := '-';
          ModelItem.Tag := TAG_SEPARATOR;
          FPopupMenu.Items.Insert(InsertPos, ModelItem);
          Inc(InsertPos);
        end;

        // Installed models
        for I := 0 to FInstalledModels.Count - 1 do
        begin
          ModelName := FInstalledModels[I];

          if FLoadingModels.IndexOf(ModelName) >= 0 then
            Continue;

          IsRunning := FRunningModels.IndexOf(ModelName) >= 0;
          IsStarting := FStartingModels.IndexOf(ModelName) >= 0;

          ModelItem := TMenuItem.Create(FPopupMenu);
          ModelItem.Caption := ModelName;
          ModelItem.Tag := TAG_MODEL;
          ModelItem.Hint := ModelName;

          if IsRunning or IsStarting then
            ModelItem.Default := True;

          if IsStarting then
          begin
            Pct := StrToIntDef(FStartingProgress.Values[ModelName], 0);

            SubItem := TMenuItem.Create(ModelItem);
            SubItem.Caption := Format(rsStartingPercent, [Pct]);
            SubItem.Hint := ModelName;
            SubItem.Enabled := False;
            ModelItem.Add(SubItem);
            FStartSubItems.AddObject(ModelName, SubItem);

            SubItem := TMenuItem.Create(ModelItem);
            SubItem.Caption := rsStopMenu;
            SubItem.Hint := ModelName;
            SubItem.Enabled := False;
            ModelItem.Add(SubItem);

            SubItem := TMenuItem.Create(ModelItem);
            SubItem.Caption := rsDeleteMenu;
            SubItem.Hint := ModelName;
            SubItem.Enabled := False;
            ModelItem.Add(SubItem);

            SubItem := TMenuItem.Create(ModelItem);
            SubItem.Caption := rsCopyNameMenu;
            SubItem.Hint := ModelName;
            SubItem.OnClick := @MenuCopyNameClick;
            ModelItem.Add(SubItem);

            SubItem := TMenuItem.Create(ModelItem);
            SubItem.Caption := rsInfoMenu;
            SubItem.Hint := ModelName;
            SubItem.OnClick := @MenuInfoClick;
            ModelItem.Add(SubItem);
          end
          else
          begin
            // Cloud models are not loaded locally, so Start/Stop make no sense for them
            if not IsCloudModel(ModelName) then
            begin
              SubItem := TMenuItem.Create(ModelItem);
              SubItem.Caption := rsStartMenu;
              SubItem.Hint := ModelName;
              SubItem.Enabled := not IsRunning;
              SubItem.OnClick := @MenuStartClick;
              ModelItem.Add(SubItem);

              SubItem := TMenuItem.Create(ModelItem);
              SubItem.Caption := rsStopMenu;
              SubItem.Hint := ModelName;
              SubItem.Enabled := IsRunning;
              SubItem.OnClick := @MenuStopClick;
              ModelItem.Add(SubItem);
            end;

            SubItem := TMenuItem.Create(ModelItem);
            SubItem.Caption := rsDeleteMenu;
            SubItem.Hint := ModelName;
            SubItem.OnClick := @MenuDeleteClick;
            ModelItem.Add(SubItem);

            SubItem := TMenuItem.Create(ModelItem);
            SubItem.Caption := rsCopyNameMenu;
            SubItem.Hint := ModelName;
            SubItem.OnClick := @MenuCopyNameClick;
            ModelItem.Add(SubItem);

            SubItem := TMenuItem.Create(ModelItem);
            SubItem.Caption := rsInfoMenu;
            SubItem.Hint := ModelName;
            SubItem.OnClick := @MenuInfoClick;
            ModelItem.Add(SubItem);
          end;

          FPopupMenu.Items.Insert(InsertPos, ModelItem);
          Inc(InsertPos);
        end;

        // Loading models (pulling) with live percent when available
        for I := 0 to FLoadingModels.Count - 1 do
        begin
          ModelItem := TMenuItem.Create(FPopupMenu);
          ProgIdx := FPullProgress.IndexOfName(FLoadingModels[I]);
          if ProgIdx >= 0 then
            ModelItem.Caption := Format(rsLoadingModelPercent, [FLoadingModels[I], StrToIntDef(
              FPullProgress.ValueFromIndex[ProgIdx], 0)])
          else
            ModelItem.Caption := Format(rsLoadingModel, [FLoadingModels[I]]);
          ModelItem.Tag := TAG_LOADING;
          ModelItem.Enabled := False;
          FLoadingSubItems.AddObject(FLoadingModels[I], ModelItem);
          FPopupMenu.Items.Insert(InsertPos, ModelItem);
          Inc(InsertPos);
        end;

        if HasModels then
          HasContentAbove := True;
      end;
    end
    else
    begin
      // Not connected yet: show a retry hint only when no attempt is running.
      // While connecting, the Connect item itself becomes the "Connecting..."
      // indicator, so there is nothing to add here.
      if (not FConnecting) and (msConnect in FMenuSections) then
      begin
        ModelItem := TMenuItem.Create(FPopupMenu);
        ModelItem.Tag := TAG_LOADING;
        ModelItem.Caption := rsDisconnectedStatus;
        ModelItem.OnClick := @MenuReconnectClick;
        FPopupMenu.Items.Insert(InsertPos, ModelItem);
        Inc(InsertPos);
        HasContentAbove := True;
      end;
    end;
  end;

  // Separator between the content block and the connection block
  if HasContentAbove then
  begin
    ModelItem := TMenuItem.Create(FPopupMenu);
    ModelItem.Caption := '-';
    ModelItem.Tag := TAG_SEPARATOR;
    FPopupMenu.Items.Insert(InsertPos, ModelItem);
    Inc(InsertPos);
  end;

  // Server item is always visible for hot switching, placed above Connect
  if msServer in FMenuSections then
  begin
    ModelItem := TMenuItem.Create(FPopupMenu);
    ModelItem.Caption := rsServerMenu;
    ModelItem.Tag := TAG_SERVER;
    ModelItem.OnClick := @MenuServerClick;
    FPopupMenu.Items.Insert(InsertPos, ModelItem);
    Inc(InsertPos);
  end;

  // Connect item: turns into a disabled "Connecting..." label only during
  // the initial connection; a background refresh of an already-connected
  // manager keeps showing "Connect" (disabled) to avoid a visual flicker
  if msConnect in FMenuSections then
  begin
    ModelItem := TMenuItem.Create(FPopupMenu);
    ModelItem.Tag := TAG_CONNECTION;
    if FConnecting and (not FConnected) then
    begin
      ModelItem.Caption := rsConnectingStatus;
      ModelItem.Enabled := False;
    end
    else
    begin
      ModelItem.Caption := rsConnectMenu;
      ModelItem.Enabled := (not FActive) or (not FConnected);
      ModelItem.OnClick := @MenuConnectClick;
    end;
    FPopupMenu.Items.Insert(InsertPos, ModelItem);
    Inc(InsertPos);

    // Disconnect is enabled only while the manager is active
    ModelItem := TMenuItem.Create(FPopupMenu);
    ModelItem.Caption := rsDisconnectMenu;
    ModelItem.Tag := TAG_CONNECTION;
    ModelItem.Enabled := FActive;
    ModelItem.OnClick := @MenuDisconnectClick;
    FPopupMenu.Items.Insert(InsertPos, ModelItem);
    Inc(InsertPos);
  end;

  // Separator between our block and user-owned items at the bottom
  ModelItem := TMenuItem.Create(FPopupMenu);
  ModelItem.Caption := '-';
  ModelItem.Tag := TAG_SEPARATOR;
  FPopupMenu.Items.Insert(InsertPos, ModelItem);
end;

procedure TCustomOllamaManager.ProgressTimerTick(Sender: TObject);
var
  I, Pct, Idx: integer;
  AName: string;
  SubItem: TMenuItem;
begin
  if FShutdown then
    Exit;

  if FStartingModels.Count = 0 then
  begin
    if Assigned(FProgressTimer) then
      FProgressTimer.Enabled := False;
    Exit;
  end;

  for I := 0 to FStartingModels.Count - 1 do
  begin
    AName := FStartingModels[I];
    Pct := StrToIntDef(FStartingProgress.Values[AName], 0);
    if Pct < 95 then
    begin
      Inc(Pct, 2);
      if Pct > 95 then
        Pct := 95;
      FStartingProgress.Values[AName] := IntToStr(Pct);
    end;

    if not Assigned(FPopupMenu) then
      Continue;

    Idx := FStartSubItems.IndexOf(AName);
    if Idx < 0 then
      Continue;

    SubItem := TMenuItem(FStartSubItems.Objects[Idx]);
    if Assigned(SubItem) then
      SubItem.Caption := Format(rsStartingPercent, [Pct]);
  end;
end;

procedure TCustomOllamaManager.RefreshModels;
begin
  // Asynchronous: starts a background refresh and returns immediately
  BeginConnect;
end;

function TCustomOllamaManager.ParseModels(const JsonStr: string; ADetails: TStringList): TStringList;
var
  Data: TJSONData;
  Arr: TJSONArray;
  Obj: TJSONObject;
  I: integer;
  AName: string;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;

  if Assigned(ADetails) then
    ADetails.Clear;

  if Trim(JsonStr) = '' then
    Exit;

  Data := nil;
  try
    try
      Data := GetJSON(JsonStr);
      if Data.JSONType <> jtObject then
        Exit;
      Arr := TJSONObject(Data).Arrays['models'];
      if not Assigned(Arr) then
        Exit;

      for I := 0 to Arr.Count - 1 do
      begin
        Obj := Arr.Objects[I];
        AName := Obj.Get('name', '');
        if AName = '' then
          AName := Obj.Get('model', '');
        if AName <> '' then
        begin
          Result.Add(AName);
          if Assigned(ADetails) then
            ADetails.Values[AName] := Obj.AsJSON;
        end;
      end;
    except
      ; // Invalid JSON - return whatever was parsed so far
    end;
  finally
    Data.Free;
  end;
end;

function TCustomOllamaManager.ValidateModelsJson(const JsonStr: string): boolean;
var
  Data, ModelsData, ItemData: TJSONData;
  Arr: TJSONArray;
  Obj: TJSONObject;
  I: integer;
  ModelName: string;
begin
  Result := False;
  Data := nil;

  try
    Data := GetJSON(JsonStr);

    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit;

    ModelsData := TJSONObject(Data).Find('models');
    if (not Assigned(ModelsData)) or (ModelsData.JSONType <> jtArray) then
      Exit;

    Arr := TJSONArray(ModelsData);

    for I := 0 to Arr.Count - 1 do
    begin
      ItemData := Arr.Items[I];

      if (ItemData = nil) or (ItemData.JSONType <> jtObject) then
        Exit;

      Obj := TJSONObject(ItemData);
      ModelName := Obj.Get('name', '');

      if ModelName = '' then
        ModelName := Obj.Get('model', '');

      if ModelName = '' then
        Exit;
    end;

    Result := True;
  except
    Result := False;
  end;

  Data.Free;
end;

function TCustomOllamaManager.IsCloudModel(const ModelName: string): boolean;
begin
  Result := ModelName.EndsWith('-cloud') or ModelName.EndsWith(':cloud');
end;

function TCustomOllamaManager.BuildModelInfo(const ModelName: string): string;
var
  SL: TStringList;
  ShowJson, PsJson: string;
  ShowData, PsData: TJSONData;
  Details: TJSONObject;
  PsObj: TJSONObject;
  Idx, VRAMPct: integer;
  ModelSize: int64;
  ModelData: TJSONData;
  FractionPos, TimeZonePos, I: integer;
  DisplayExpiresAt: string;
  Kind: TOllamaErrorKind;
  ErrMsg: string;
  Family, ParamSize, Quant, Fmt, ModifiedAt, ExpiresAt: string;
  SizeTotal, SizeVram, CtxLen: int64;
  Found: boolean;
begin
  SL := TStringList.Create;
  try
    SL.Add(ModelName);
    if IsCloudModel(ModelName) then
      SL.Add(rsInfoCloudModel);
    SL.Add('');

    // Display model size from the cached /api/tags response
    Idx := FInstalledDetails.IndexOfName(ModelName);
    if Idx >= 0 then
    begin
      ModelData := nil;
      try
        ModelData := GetJSON(FInstalledDetails.ValueFromIndex[Idx]);
        if ModelData.JSONType = jtObject then
        begin
          ModelSize := TJSONObject(ModelData).Get('size', int64(0));
          if ModelSize > 0 then
            SL.Add(Format(rsInfoModelSize, [BytesToHuman(ModelSize)]));
        end;
      finally
        ModelData.Free;
      end;
    end;

    // Fetch metadata from /api/show
    ShowJson := ApiPost('/api/show', Format('{"name":"%s"}', [ModelName]), Kind, ErrMsg);
    if Kind = oekNone then
    begin
      ShowData := nil;
      try
        try
          ShowData := GetJSON(ShowJson);
          if ShowData.JSONType = jtObject then
          begin
            Details := TJSONObject(ShowData).Objects['details'];
            if Assigned(Details) then
            begin
              Fmt := Details.Get('format', '');
              Family := Details.Get('family', '');
              ParamSize := Details.Get('parameter_size', '');
              Quant := Details.Get('quantization_level', '');
              if Fmt <> '' then
                SL.Add(Format(rsInfoFormat, [Fmt]));
              if Family <> '' then
                SL.Add(Format(rsInfoFamily, [Family]));
              if ParamSize <> '' then
                SL.Add(Format(rsInfoParameters, [ParamSize]));
              if Quant <> '' then
                SL.Add(Format(rsInfoQuantization, [Quant]));
            end;
            ModifiedAt := TJSONObject(ShowData).Get('modified_at', '');
            if ModifiedAt <> '' then
              SL.Add(Format(rsInfoModified, [ModifiedAt]));
          end;
        except
          on E: Exception do
            SL.Add(Format(rsInfoMetadataError, [E.Message]));
        end;
      finally
        ShowData.Free;
      end;
    end
    else
      SL.Add(Format(rsInfoMetadataError, [ErrMsg]));

    SL.Add('');
    SL.Add(rsInfoRunningHeader);

    // Look up running details cached by the background refresh
    Found := False;
    Idx := FRunningDetails.IndexOfName(ModelName);
    if Idx >= 0 then
    begin
      PsJson := FRunningDetails.ValueFromIndex[Idx];
      PsData := nil;
      try
        try
          PsData := GetJSON(PsJson);
          if PsData.JSONType = jtObject then
          begin
            PsObj := TJSONObject(PsData);
            SizeTotal := PsObj.Get('size', int64(0));
            SizeVram := PsObj.Get('size_vram', int64(0));
            CtxLen := PsObj.Get('context_length', int64(0));
            ExpiresAt := PsObj.Get('expires_at', '');
            SL.Add(Format(rsInfoStatus, [rsInfoStatusLoaded]));
            if SizeTotal > 0 then
              SL.Add(Format(rsInfoTotalMemory, [BytesToHuman(SizeTotal)]));
            if SizeVram > 0 then
            begin
              if SizeTotal > 0 then
                VRAMPct := Round(SizeVram * 100 / SizeTotal)
              else
                VRAMPct := 0;
              SL.Add(Format(rsInfoVram, [BytesToHuman(SizeVram), VRAMPct]));
            end;
            if CtxLen > 0 then
              SL.Add(Format(rsInfoContextLength, [CtxLen]));
            if ExpiresAt <> '' then
            begin
              // Limit fractional seconds to milliseconds for FPC compatibility
              DisplayExpiresAt := ExpiresAt;
              FractionPos := Pos('.', DisplayExpiresAt);
              if FractionPos > 0 then
              begin
                TimeZonePos := Length(DisplayExpiresAt) + 1;
                for I := FractionPos + 1 to Length(DisplayExpiresAt) do
                  if (DisplayExpiresAt[I] = '+') or (DisplayExpiresAt[I] = '-') or (DisplayExpiresAt[I] = 'Z') then
                  begin
                    TimeZonePos := I;
                    Break;
                  end;

                if TimeZonePos - FractionPos - 1 > 3 then
                  DisplayExpiresAt :=
                    Copy(DisplayExpiresAt, 1, FractionPos + 3) + Copy(DisplayExpiresAt, TimeZonePos, MaxInt);
              end;

              if Copy(ExpiresAt, 1, 4) = '2319' then
                SL.Add(Format(rsInfoUnloadsAt, [rsKeepAliveForever]))
              else
                SL.Add(Format(rsInfoUnloadsAt, [DateTimeToStr(ISO8601ToDate(DisplayExpiresAt, False))]));
            end;
            Found := True;
          end;
        except
          ; // Invalid cached JSON, treat as not loaded
        end;
      finally
        PsData.Free;
      end;
    end;

    if not Found then
      SL.Add(Format(rsInfoStatus, [rsInfoStatusNotLoaded]));

    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function TCustomOllamaManager.DoRequest(AMethod: TWebMethod; const Endpoint, JsonBody: string;
  out Kind: TOllamaErrorKind; out ErrorMsg: string; ARequestTimeout: integer): string;
const
  // Connection and timeout failures are retried, HTTP errors are not
  MAX_ATTEMPTS = 3;
var
  Headers: TStringList;
  ResponseHeaders: TStringList;
  Cookies: TStringList;
  Err: boolean;
  SockErr: boolean;
  Tm: TTimeout;
  HTTP: TNetworkHTTP;
  ContentType: string;
  ErrJSON: TJSONData;
  ErrTxt: string;
  Attempt: integer;
  Success: boolean;
begin
  Kind := oekNone;
  ErrorMsg := '';
  Result := '';

  if FShutdown then
  begin
    Kind := oekCancelled;
    ErrorMsg := rsConnectionError;
    Exit;
  end;

  Headers := TStringList.Create;
  Cookies := TStringList.Create;
  ResponseHeaders := nil;
  HTTP := nil;

  Tm.Connection := FConnectionTimeout;
  if ARequestTimeout > 0 then
    Tm.Request := ARequestTimeout
  else
    Tm.Request := FRequestTimeout;

  if AMethod = wmPost then
    ContentType := 'application/json'
  else
    ContentType := '';

  try
    for Attempt := 1 to MAX_ATTEMPTS do
    begin
      // Reset resources from the previous attempt before retrying
      FreeAndNil(HTTP);
      FreeAndNil(ResponseHeaders);
      Kind := oekNone;
      ErrorMsg := '';
      Result := '';
      Success := False;
      try
        Result := TNetwork.WebRequest(AMethod, FBaseURL + Endpoint, JsonBody, Headers, 'OllamaManager/1.0',
          ContentType, 'application/json', False, Default(TProxy), Tm, Cookies, ResponseHeaders, Err, HTTP);

        if not Err then
        begin
          Success := True;
          Break;
        end;

        // Socket errors take priority over HTTP code classification
        SockErr := (HTTP <> nil) and (HTTP.LastError <> 0);
        if SockErr then
          Kind := oekConnection
        else if (HTTP <> nil) and (HTTP.ResultCode <> 0) then
          Kind := ClassifyHttp(HTTP.ResultCode)
        else
          Kind := oekConnection;

        // Try to extract the "error" field from a JSON error body
        if Result.IsJson then
        begin
          ErrJSON := nil;
          try
            try
              ErrJSON := GetJSON(Result);
              if (ErrJSON <> nil) and (ErrJSON.JSONType = jtObject) then
              begin
                ErrTxt := TJSONObject(ErrJSON).Get('error', '');
                if ErrTxt <> '' then
                  ErrorMsg := ErrTxt
                else
                  ErrorMsg := Result;
              end
              else
                ErrorMsg := Result;
            except
              ErrorMsg := Result;
            end;
          finally
            ErrJSON.Free;
          end;
        end
        else
          ErrorMsg := Result;

        ErrorMsg := Trim(ErrorMsg);
        if ErrorMsg = '' then
        begin
          if SockErr then
            ErrorMsg := Format('Socket error %d: %s', [HTTP.LastError, Trim(HTTP.LastErrorDesc)])
          else if (HTTP <> nil) and (HTTP.ResultCode <> 0) then
            ErrorMsg := Format(rsHttpError, [HTTP.ResultCode, Trim(HTTP.ResultString)])
          else
            ErrorMsg := rsConnectionError;
          if Trim(ErrorMsg) = '' then
            ErrorMsg := 'Empty error response from server';
        end;
        Result := '';

        // Retry only connection and timeout failures, HTTP errors are final
        if not (Kind in [oekConnection, oekTimeout]) then
          Break;
        if Attempt = MAX_ATTEMPTS then
          Break;
        Sleep(200 * Attempt);
      except
        on E: Exception do
        begin
          Kind := oekConnection;
          ErrorMsg := E.Message;
          Result := '';
          if Attempt = MAX_ATTEMPTS then
            Break;
          Sleep(200 * Attempt);
        end;
      end;
    end;

    // Defensive net in case the loop finished without an explicit error
    if (not Success) and (Kind = oekNone) then
    begin
      Kind := oekConnection;
      if ErrorMsg = '' then
        ErrorMsg := rsConnectionError;
    end;
  finally
    Headers.Free;
    Cookies.Free;
    ResponseHeaders.Free;
    HTTP.Free;
  end;
end;

function TCustomOllamaManager.ApiGet(const Endpoint: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): string;
begin
  Result := DoRequest(wmGet, Endpoint, '', Kind, ErrorMsg);
end;

function TCustomOllamaManager.ApiPost(const Endpoint, JsonBody: string; out Kind: TOllamaErrorKind;
  out ErrorMsg: string; ARequestTimeout: integer): string;
begin
  Result := DoRequest(wmPost, Endpoint, JsonBody, Kind, ErrorMsg, ARequestTimeout);
end;

function TCustomOllamaManager.RawDelete(const Endpoint, JsonBody: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean;
var
  HTTP: THTTPSend;
  PostStream: TStringStream;
begin
  Kind := oekNone;
  ErrorMsg := '';
  Result := False;

  if FShutdown then
  begin
    Kind := oekCancelled;
    ErrorMsg := rsConnectionError;
    Exit;
  end;

  HTTP := THTTPSend.Create;
  try
    HTTP.Protocol := '1.1';
    HTTP.MimeType := 'application/json';
    HTTP.Timeout := FRequestTimeout;
    HTTP.Sock.ConnectionTimeout := FConnectionTimeout;

    PostStream := TStringStream.Create(JsonBody, TEncoding.UTF8);
    try
      HTTP.Document.CopyFrom(PostStream, 0);
      HTTP.Document.Position := 0;
    finally
      PostStream.Free;
    end;

    try
      HTTP.HTTPMethod('DELETE', FBaseURL + Endpoint);
    except
      on E: Exception do
      begin
        Kind := oekConnection;
        ErrorMsg := E.Message;
        Exit;
      end;
    end;

    if (HTTP.ResultCode div 100) = 2 then
      Result := True
    else
    begin
      Kind := ClassifyHttp(HTTP.ResultCode);
      ErrorMsg := Format(rsHttpError, [HTTP.ResultCode, HTTP.ResultString]);
    end;
  finally
    HTTP.Free;
  end;
end;

procedure TCustomOllamaManager.MenuPullClick(Sender: TObject);
var
  ModelName: string;
begin
  ModelName := '';
  if InputQueryLite(rsPullCaption, rsPullPrompt, ModelName) then
  begin
    ModelName := Trim(ModelName);
    if ModelName <> '' then
      PullModel(ModelName);
  end;
end;

procedure TCustomOllamaManager.MenuServerClick(Sender: TObject);
var
  ServerURL: string;
begin
  ServerURL := FBaseURL;
  if InputQueryLite(rsServerCaption, rsServerPrompt, ServerURL) then
  begin
    ServerURL := Trim(ServerURL);
    if ServerURL <> '' then
      BaseURL := ServerURL;
  end;
end;

procedure TCustomOllamaManager.MenuStartClick(Sender: TObject);
var
  Item: TMenuItem;
begin
  Item := TMenuItem(Sender);
  StartModel(Item.Hint);
end;

procedure TCustomOllamaManager.MenuStopClick(Sender: TObject);
var
  Item: TMenuItem;
begin
  Item := TMenuItem(Sender);
  StopModel(Item.Hint);
end;

procedure TCustomOllamaManager.MenuDeleteClick(Sender: TObject);
var
  Item: TMenuItem;
  ModelName: string;
begin
  Item := TMenuItem(Sender);
  ModelName := Item.Hint;
  if MessageDlg(Format(rsDeleteConfirm, [ModelName]), mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    DeleteModel(ModelName);
end;

procedure TCustomOllamaManager.MenuCopyNameClick(Sender: TObject);
var
  Item: TMenuItem;
begin
  Item := TMenuItem(Sender);
  Clipboard.AsText := Item.Hint;
end;

procedure TCustomOllamaManager.MenuInfoClick(Sender: TObject);
var
  Item: TMenuItem;
  ModelName, Info: string;
begin
  Item := TMenuItem(Sender);
  ModelName := Item.Hint;
  Info := '';
  try
    Info := BuildModelInfo(ModelName);
  except
    on E: Exception do
    begin
      DoError(oekUnknown, ModelName, E.Message);
      Exit;
    end;
  end;
  if Info <> '' then
    ShowMessage(Info);
end;

procedure TCustomOllamaManager.MenuReconnectClick(Sender: TObject);
begin
  BeginConnect;
end;

procedure TCustomOllamaManager.MenuConnectClick(Sender: TObject);
begin
  if not FActive then
    SetActive(True)
  else
    BeginConnect;
end;

procedure TCustomOllamaManager.MenuDisconnectClick(Sender: TObject);
begin
  SetActive(False);
end;

procedure TCustomOllamaManager.MenuKeepAliveClick(Sender: TObject);
var
  Item: TMenuItem;
begin
  Item := TMenuItem(Sender);
  FKeepAlive := Item.Tag;
  BuildPopupMenu;
end;

procedure TCustomOllamaManager.PullModel(const ModelName: string);
var
  Idx: integer;
begin
  if FShutdown then
    Exit;
  if FLoadingModels.IndexOf(ModelName) >= 0 then
    Exit;
  FLoadingModels.Add(ModelName);
  // Clear any stale progress so the caption starts without percent
  Idx := FPullProgress.IndexOfName(ModelName);
  if Idx >= 0 then
    FPullProgress.Delete(Idx);
  if Assigned(FPopupMenu) then
    BuildPopupMenu;
  TOllamaBgThread.Create(Self, boPull, ModelName);
end;

procedure TCustomOllamaManager.DeleteModel(const ModelName: string);
var
  JsonBody: string;
  Kind: TOllamaErrorKind;
  ErrMsg: string;
begin
  if FShutdown then
    Exit;

  JsonBody := Format('{"name":"%s"}', [ModelName]);
  if not RawDelete('/api/delete', JsonBody, Kind, ErrMsg) then
  begin
    DoError(Kind, ModelName, ErrMsg);
    Exit;
  end;

  BeginConnect;
end;

procedure TCustomOllamaManager.StartModel(const ModelName: string);
begin
  if FShutdown then
    Exit;
  // Cloud models cannot be loaded into local memory; ignore the request
  if IsCloudModel(ModelName) then
    Exit;
  if FStartingModels.IndexOf(ModelName) >= 0 then
    Exit;

  FStartingModels.Add(ModelName);
  FStartingProgress.Values[ModelName] := '0';

  if Assigned(FPopupMenu) then
    BuildPopupMenu;

  if Assigned(FProgressTimer) and not FProgressTimer.Enabled then
    FProgressTimer.Enabled := True;

  FInternalModelChanges.Values[ModelName] := 'Start';
  TOllamaBgThread.Create(Self, boStart, ModelName);
end;

procedure TCustomOllamaManager.StopModel(const ModelName: string);
begin
  if FShutdown then
    Exit;
  // Cloud models are not loaded locally, nothing to unload
  if IsCloudModel(ModelName) then
    Exit;

  FInternalModelChanges.Values[ModelName] := 'Stop';
  TOllamaBgThread.Create(Self, boStop, ModelName);
end;

function TCustomOllamaManager.Generate(const ModelName, Prompt: string): string;
var
  JsonBody: string;
  Kind: TOllamaErrorKind;
  ErrMsg: string;
begin
  JsonBody := Format('{"model":"%s","prompt":"%s","keep_alive":%d,"stream":false%s}',
    [ModelName, Prompt.EscapeText, FKeepAlive, BuildOptionsJson]);
  Result := ApiPost('/api/generate', JsonBody, Kind, ErrMsg);
  if Kind <> oekNone then
  begin
    DoError(Kind, ModelName, ErrMsg);
    Result := '';
  end;
end;

function TCustomOllamaManager.Chat(const ModelName, UserMessage: string): string;
var
  JsonBody: string;
  Kind: TOllamaErrorKind;
  ErrMsg: string;
begin
  JsonBody := Format('{"model":"%s","messages":[{"role":"user","content":"%s"}],"keep_alive":%d,"stream":false%s}',
    [ModelName, UserMessage.EscapeText, FKeepAlive, BuildOptionsJson]);
  Result := ApiPost('/api/chat', JsonBody, Kind, ErrMsg);
  if Kind <> oekNone then
  begin
    DoError(Kind, ModelName, ErrMsg);
    Result := '';
  end;
end;

function TCustomOllamaManager.ShowModel(const ModelName: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): string;
var
  JsonBody: string;
begin
  JsonBody := Format('{"name":"%s"}', [ModelName.EscapeText]);
  Result := ApiPost('/api/show', JsonBody, Kind, ErrorMsg);
  if Kind <> oekNone then
  begin
    DoError(Kind, ModelName, ErrorMsg);
    Result := '';
  end;
end;

function TCustomOllamaManager.GetVersion(out Kind: TOllamaErrorKind; out ErrorMsg: string): string;
var
  Data: TJSONData;
begin
  Result := ApiGet('/api/version', Kind, ErrorMsg);
  if Kind <> oekNone then
  begin
    DoError(Kind, '', ErrorMsg);
    Result := '';
    Exit;
  end;
  // Extract version field from the JSON response
  Data := nil;
  try
    try
      Data := GetJSON(Result);
      if (Data <> nil) and (Data.JSONType = jtObject) then
        Result := TJSONObject(Data).Get('version', Result);
    except
      ; // Return raw JSON when parsing fails
    end;
  finally
    Data.Free;
  end;
end;

function TCustomOllamaManager.CopyModel(const Source, Destination: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean;
var
  JsonBody: string;
begin
  JsonBody := Format('{"source":"%s","destination":"%s"}', [Source.EscapeText, Destination.EscapeText]);
  // Response body is not needed, success is reported through Kind
  ApiPost('/api/copy', JsonBody, Kind, ErrorMsg);
  Result := Kind = oekNone;
  if Kind <> oekNone then
    DoError(Kind, Source, ErrorMsg);
end;

function TCustomOllamaManager.CreateModel(const ModelName, ModelfileContent: string; out Kind: TOllamaErrorKind;
  out ErrorMsg: string): boolean;
var
  JsonBody: string;
begin
  JsonBody := Format('{"name":"%s","modelfile":"%s","stream":false}', [ModelName.EscapeText, ModelfileContent.EscapeText]);
  // Response body is not needed, success is reported through Kind
  ApiPost('/api/create', JsonBody, Kind, ErrorMsg);
  Result := Kind = oekNone;
  if Kind <> oekNone then
    DoError(Kind, ModelName, ErrorMsg);
end;

function TCustomOllamaManager.LoadModelSync(const ModelName: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean;
var
  JsonBody: string;
begin
  JsonBody := Format('{"model":"%s","prompt":"","keep_alive":%d,"stream":false}', [ModelName.EscapeText, FKeepAlive]);
  // Response body is not needed, success is reported through Kind
  ApiPost('/api/generate', JsonBody, Kind, ErrorMsg);
  Result := Kind = oekNone;
  if Kind <> oekNone then
    DoError(Kind, ModelName, ErrorMsg);
end;

function TCustomOllamaManager.UnloadModelSync(const ModelName: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean;
var
  JsonBody: string;
begin
  JsonBody := Format('{"model":"%s","prompt":"","keep_alive":0,"stream":false}', [ModelName.EscapeText]);
  // Response body is not needed, success is reported through Kind
  ApiPost('/api/generate', JsonBody, Kind, ErrorMsg);
  Result := Kind = oekNone;
  if Kind <> oekNone then
    DoError(Kind, ModelName, ErrorMsg);
end;

procedure TCustomOllamaManager.SetMonitorModelState(const Value: boolean);
begin
  if FMonitorModelState = Value then
    Exit;

  FMonitorModelState := Value;

  // Establish a fresh baseline after monitoring is enabled
  FMonitorInitialized := False;

  if Assigned(FMonitorTimer) then
  begin
    FMonitorTimer.Enabled := Value and FActive;
    if Value then
    begin
      if FConnected then
        FMonitorTimer.Interval := FMonitorInterval
      else
        FMonitorTimer.Interval := MONITOR_RETRY_INTERVAL;
    end;
  end;
end;

procedure TCustomOllamaManager.SetMonitorInterval(const Value: integer);
begin
  if Value < 500 then
    FMonitorInterval := 500
  else
    FMonitorInterval := Value;

  if Assigned(FMonitorTimer) then
  begin
    if FConnected then
      FMonitorTimer.Interval := FMonitorInterval
    else
      FMonitorTimer.Interval := MONITOR_RETRY_INTERVAL;
  end;
end;

procedure TCustomOllamaManager.MonitorTimerTick(Sender: TObject);
begin
  if FShutdown or not FMonitorModelState or not FActive then
    Exit;

  // Refresh only when no other connection attempt is in progress
  if not FConnecting then
    BeginConnect;
end;

type
  // Internal helper that parses SSE chunks and forwards content and thinking
  TOllamaChatStreamHelper = class
  public
    Buffer: string;
    FullFinal: string;
    AccumulatedToolCalls: string;
    LastPromptEvalCount: integer;
    LastEvalCount: integer;
    LastPromptEvalCachedCount: int64;
    LastPromptEvalDuration: int64;
    LastEvalDuration: int64;
    LastTotalDuration: int64;
    LastLoadDuration: int64;
    Done: boolean;
    Cancelled: boolean;
    UserCallback: TOllamaStreamCallback;
    ThinkingCallback: TOllamaStreamCallback;
    function ParseChunk(const ALine: string; var AContent, AThinking, AToolCalls: string; var ADone: boolean): boolean;
    procedure HandleRaw(const AChunk: string; var ACancel: boolean);
  end;

function TOllamaChatStreamHelper.ParseChunk(const ALine: string; var AContent, AThinking, AToolCalls: string;
  var ADone: boolean): boolean;
var
  Data, MsgData, ToolCallsData: TJSONData;
  Obj, Msg: TJSONObject;
begin
  Result := False;
  AContent := '';
  AThinking := '';
  AToolCalls := '';
  ADone := False;
  Data := nil;
  try
    try
      Data := GetJSON(ALine);
      if (Data = nil) or (Data.JSONType <> jtObject) then
        Exit;
      Obj := TJSONObject(Data);
      MsgData := Obj.Find('message');
      if (MsgData <> nil) and (MsgData.JSONType = jtObject) then
      begin
        Msg := TJSONObject(MsgData);
        AContent := Msg.Get('content', '');
        AThinking := Msg.Get('thinking', '');
        ToolCallsData := Msg.Find('tool_calls');
        if (ToolCallsData <> nil) and (ToolCallsData.JSONType = jtArray) and (TJSONArray(ToolCallsData).Count > 0) then
          AToolCalls := ToolCallsData.AsJSON;
      end;
      ADone := Obj.Get('done', False);
      // Usage counters only present in the final chunk
      if ADone then
      begin
        LastPromptEvalCount := Obj.Get('prompt_eval_count', 0);
        LastEvalCount := Obj.Get('eval_count', 0);
        LastPromptEvalCachedCount := Obj.Get('prompt_eval_cached_count', int64(-1));
        LastPromptEvalDuration := Obj.Get('prompt_eval_duration', int64(0));
        LastEvalDuration := Obj.Get('eval_duration', int64(0));
        LastTotalDuration := Obj.Get('total_duration', int64(0));
        LastLoadDuration := Obj.Get('load_duration', int64(0));
      end;
      Result := True;
    except
      Result := False;
    end;
  finally
    Data.Free;
  end;
end;

procedure TOllamaChatStreamHelper.HandleRaw(const AChunk: string; var ACancel: boolean);
var
  P: integer;
  OneLine, ChunkContent, ChunkThinking, ChunkToolCalls: string;
  IsDone: boolean = False;
begin
  Buffer := Buffer + AChunk;
  ChunkContent := '';
  ChunkThinking := '';
  ChunkToolCalls := '';
  P := Pos(#10, Buffer);
  while P > 0 do
  begin
    OneLine := Trim(Copy(Buffer, 1, P - 1));
    Buffer := Copy(Buffer, P + 1, MaxInt);
    if OneLine <> '' then
    begin
      if ParseChunk(OneLine, ChunkContent, ChunkThinking, ChunkToolCalls, IsDone) then
      begin
        // Accumulate tool_calls, they arrive before the final done chunk
        if ChunkToolCalls <> '' then
          AccumulatedToolCalls := ChunkToolCalls;
        if IsDone then
        begin
          // Synthesize final chunk with any accumulated tool_calls
          if AccumulatedToolCalls <> '' then
            FullFinal := '{"message":{"role":"assistant","content":"","tool_calls":' + AccumulatedToolCalls + '},"done":true}'
          else
            FullFinal := OneLine;
        end;
        // Emit thinking first, then content
        if (ChunkThinking <> '') and Assigned(ThinkingCallback) then
        begin
          Cancelled := ACancel;
          ThinkingCallback(ChunkThinking, Cancelled);
          ACancel := Cancelled;
        end;
        if (ChunkContent <> '') and Assigned(UserCallback) then
        begin
          Cancelled := ACancel;
          UserCallback(ChunkContent, Cancelled);
          ACancel := Cancelled;
        end;
        if IsDone then
        begin
          Done := True;
          ACancel := True;
        end;
      end;
    end;
    if ACancel then
      Break;
    P := Pos(#10, Buffer);
  end;
end;

function TCustomOllamaManager.ChatStream(const ModelName, MessagesJson, ToolsJson: string; AOnChunk: TOllamaStreamCallback;
  out AKind: TOllamaErrorKind; out AErrorMsg: string): string;
begin
  Result := ChatStream(ModelName, MessagesJson, ToolsJson, AOnChunk, nil, AKind, AErrorMsg);
end;

function TCustomOllamaManager.ChatStream(const ModelName, MessagesJson, ToolsJson: string;
  AOnContent, AOnThinking: TOllamaStreamCallback; out AKind: TOllamaErrorKind; out AErrorMsg: string): string;
var
  JsonBody, ErrFromNetwork, Url, UpperError: string;
  Tm: TTimeout;
  Helper: TOllamaChatStreamHelper;
  HttpPos, HttpCode: integer;
begin
  Result := '';
  AKind := oekNone;
  AErrorMsg := '';
  if Trim(MessagesJson) = '' then
  begin
    AKind := oekUnknown;
    AErrorMsg := 'Empty messages';
    Exit;
  end;

  if ToolsJson <> '' then
    JsonBody := Format('{"model":"%s","messages":%s,"tools":%s,"keep_alive":%d%s,"stream":true}',
      [ModelName, MessagesJson, ToolsJson, FKeepAlive, BuildOptionsJson])
  else
    JsonBody := Format('{"model":"%s","messages":%s,"keep_alive":%d%s,"stream":true}',
      [ModelName, MessagesJson, FKeepAlive, BuildOptionsJson]);

  Tm.Connection := FConnectionTimeout;
  Tm.Request := FRequestTimeout;
  Url := FBaseURL + '/api/chat';

  Helper := TOllamaChatStreamHelper.Create;
  try
    Helper.Buffer := '';
    Helper.FullFinal := '';
    Helper.AccumulatedToolCalls := '';
    Helper.Done := False;
    Helper.Cancelled := False;
    Helper.UserCallback := AOnContent;
    Helper.ThinkingCallback := AOnThinking;
    Helper.LastPromptEvalCachedCount := -1;
    Helper.LastPromptEvalDuration := 0;
    Helper.LastEvalDuration := 0;
    Helper.LastTotalDuration := 0;
    Helper.LastLoadDuration := 0;

    ErrFromNetwork := '';
    if not TNetwork.WebStreamRequest(wmPost, Url, JsonBody, nil, 'OllamaManager/1.0', 'application/json',
      'application/json', Tm, @Helper.HandleRaw, ErrFromNetwork) then
    begin
      AKind := oekConnection;
      UpperError := UpperCase(ErrFromNetwork);
      HttpPos := Pos('HTTP ', UpperError);
      if HttpPos > 0 then
      begin
        HttpCode := StrToIntDef(Copy(UpperError, HttpPos + 5, 3), 0);
        if (HttpCode >= 400) and (HttpCode < 600) then
          AKind := ClassifyHttp(HttpCode);
      end;

      AErrorMsg := Format('POST %s, model="%s", request_bytes=%d: %s', [Url, ModelName, Length(JsonBody), Trim(ErrFromNetwork)]);
      if AErrorMsg = '' then
        AErrorMsg := 'Streaming request failed';

      DoError(AKind, ModelName, AErrorMsg);
      Exit;
    end;

    if Helper.Cancelled and not Helper.Done then
    begin
      AKind := oekCancelled;
      AErrorMsg := 'Cancelled by user';
      Exit;
    end;

    // Log incomplete streams to help diagnose interrupted generations
    if not Helper.Done then
    begin
      AErrorMsg := Format('Incomplete stream: done=%s, buffer=%d, final=%d, tool_calls=%d, request_bytes=%d, error="%s"',
        [BoolToStr(Helper.Done, True), Length(Helper.Buffer), Length(Helper.FullFinal), Length(Helper.AccumulatedToolCalls),
        Length(JsonBody), Trim(ErrFromNetwork)]);
      AKind := oekUnknown;
      Exit;
    end;

    // Store usage counters reported by the server
    FLastPromptEvalCount := Helper.LastPromptEvalCount;
    FLastEvalCount := Helper.LastEvalCount;

    FLastRequestStats := Format('prompt=%d cached=%d prompt_ms=%d eval=%d eval_ms=%d total_ms=%d load_ms=%d',
      [Helper.LastPromptEvalCount, Helper.LastPromptEvalCachedCount, Helper.LastPromptEvalDuration div
      1000000, Helper.LastEvalCount, Helper.LastEvalDuration div 1000000, Helper.LastTotalDuration div
      1000000, Helper.LastLoadDuration div 1000000]);

    Result := Helper.FullFinal;
  finally
    Helper.Free;
  end;
end;

function TCustomOllamaManager.ChatWithTools(const ModelName, MessagesJson, ToolsJson: string; out AKind: TOllamaErrorKind;
  out AErrorMsg: string): string;
begin
  Result := ChatWithTools(ModelName, MessagesJson, ToolsJson, nil, nil, AKind, AErrorMsg);
end;

function TCustomOllamaManager.ChatWithTools(const ModelName, MessagesJson, ToolsJson: string;
  AOnContent, AOnThinking: TOllamaStreamCallback; out AKind: TOllamaErrorKind; out AErrorMsg: string): string;
var
  JsonBody, ContentStr, ThinkingStr: string;
  Data, MsgData: TJSONData;
  Cancelled: boolean;
begin
  Result := '';
  AKind := oekNone;
  AErrorMsg := '';
  if Trim(MessagesJson) = '' then
  begin
    AKind := oekUnknown;
    AErrorMsg := 'Empty messages';
    Exit;
  end;
  if ToolsJson <> '' then
    JsonBody := Format('{"model":"%s","messages":%s,"tools":%s,"keep_alive":%d%s,"stream":false}',
      [ModelName, MessagesJson, ToolsJson, FKeepAlive, BuildOptionsJson])
  else
    JsonBody := Format('{"model":"%s","messages":%s,"keep_alive":%d%s,"stream":false}', [ModelName,
      MessagesJson, FKeepAlive, BuildOptionsJson]);
  Result := ApiPost('/api/chat', JsonBody, AKind, AErrorMsg);
  if AKind <> oekNone then
  begin
    DoError(AKind, ModelName, AErrorMsg);
    Result := '';
    Exit;
  end;
  if Trim(Result) = '' then
  begin
    AKind := oekUnknown;
    AErrorMsg := 'Empty response from server';
    DoError(AKind, ModelName, AErrorMsg);
    Exit;
  end;
  // Emit thinking and content as single chunks from the full response
  Data := nil;
  try
    try
      Data := GetJSON(Result);
      if (Data <> nil) and (Data.JSONType = jtObject) then
      begin
        // Extract usage counters from the top-level response
        FLastPromptEvalCount := TJSONObject(Data).Get('prompt_eval_count', 0);
        FLastEvalCount := TJSONObject(Data).Get('eval_count', 0);
        MsgData := TJSONObject(Data).Find('message');
        if (MsgData <> nil) and (MsgData.JSONType = jtObject) then
        begin
          ThinkingStr := TJSONObject(MsgData).Get('thinking', '');
          ContentStr := TJSONObject(MsgData).Get('content', '');
          if (ThinkingStr <> '') and Assigned(AOnThinking) then
          begin
            Cancelled := False;
            AOnThinking(ThinkingStr, Cancelled);
          end;
          if (ContentStr <> '') and Assigned(AOnContent) then
          begin
            Cancelled := False;
            AOnContent(ContentStr, Cancelled);
          end;
        end;
      end;
    except
      ; // Ignore parse errors, caller still gets raw response
    end;
  finally
    Data.Free;
  end;
end;

end.
