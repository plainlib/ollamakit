//-----------------------------------------------------------------------------------
//  OllamaKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit OllamaManager;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Menus, Dialogs, ExtCtrls, fpjson, jsonparser,
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
  TOllamaMenuSection = (msPull, msServer, msModels, msConnect);
  TOllamaMenuSections = set of TOllamaMenuSection;

  { Event fired when the model list is refreshed }
  TModelsRefreshedEvent = procedure(Sender: TObject; const Models: TStringList) of object;
  { Event fired on any error, never raises }
  TOllamaErrorEvent = procedure(Sender: TObject; Kind: TOllamaErrorKind; const ModelName: string; const ErrorMsg: string) of object;
  { Event fired when pull progress changes (simplified: only start/finish) }
  TPullProgressEvent = procedure(Sender: TObject; const ModelName: string; Percent: integer) of object;
  { Event fired before a background refresh/connection attempt starts }
  TConnectingEvent = procedure(Sender: TObject) of object;
  { Event fired after a successful refresh/connection }
  TConnectedEvent = procedure(Sender: TObject) of object;

  { Background operation kinds }
  TOllamaBgOp = (boPull, boStart, boStop, boRefresh);

  TCustomOllamaManager = class;

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
    FAutoRefresh: boolean;
    FConnectionTimeout: integer;
    FRequestTimeout: integer;
    FPullTimeout: integer;
    FMenuSections: TOllamaMenuSections;

    FOnModelsRefreshed: TModelsRefreshedEvent;
    FOnError: TOllamaErrorEvent;
    FOnPullProgress: TPullProgressEvent;
    FOnConnecting: TConnectingEvent;
    FOnConnected: TConnectedEvent;

    // Internal state
    FInstalledModels: TStringList;
    FRunningModels: TStringList;
    FRunningDetails: TStringList;   // Name=Full JSON object from /api/ps
    FLoadingModels: TStringList;
    FStartingModels: TStringList;
    FStartingProgress: TStringList; // Name=Percent
    FStartSubItems: TStringList;    // Name=Object (TMenuItem)
    FActiveThreads: TList;
    FProgressTimer: TTimer;
    FConnecting: boolean;
    FConnected: boolean;
    FActive: boolean;
    FConnectGen: integer;
    FShutdown: boolean;

    // Popup menu handling
    FPrevPopupHandler: TNotifyEvent;
    procedure DoPopup(Sender: TObject);
    procedure BuildPopupMenu;
    procedure ClearPopupMenu;

    // HTTP helpers, none of these raise exceptions
    function DoRequest(AMethod: TWebMethod; const Endpoint, JsonBody: string; out Kind: TOllamaErrorKind;
      out ErrorMsg: string): string;
    function ApiGet(const Endpoint: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): string;
    function ApiPost(const Endpoint, JsonBody: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): string;
    function RawDelete(const Endpoint, JsonBody: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): boolean;
    function ParseModels(const JsonStr: string; ADetails: TStringList): TStringList;
    function IsCloudModel(const ModelName: string): boolean;
    function BuildModelInfo(const ModelName: string): string;

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
    procedure MenuInfoClick(Sender: TObject);
    procedure MenuReconnectClick(Sender: TObject);
    procedure MenuConnectClick(Sender: TObject);
    procedure MenuDisconnectClick(Sender: TObject);

    // Timer
    procedure ProgressTimerTick(Sender: TObject);

    // Setters
    procedure SetBaseURL(const Value: string);
    procedure SetPopupMenu(Value: TPopupMenu);
    procedure SetActive(const Value: boolean);
    procedure SetMenuSections(const Value: TOllamaMenuSections);

  protected
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

    // Called by the background thread via Synchronize
    procedure BgFinished(const ModelName: string; Kind: TOllamaErrorKind; const ErrorMsg: string);
    procedure UnregisterThread(AThread: TThread);

    property BaseURL: string read FBaseURL write SetBaseURL;
    property PopupMenu: TPopupMenu read FPopupMenu write SetPopupMenu;
    property Active: boolean read FActive write SetActive default True;
    property IsConnected: boolean read FConnected;
    property IsConnecting: boolean read FConnecting;
    property KeepAlive: integer read FKeepAlive write FKeepAlive default -1;
    property AutoRefresh: boolean read FAutoRefresh write FAutoRefresh default True;
    property ConnectionTimeout: integer read FConnectionTimeout write FConnectionTimeout default 5000;
    property RequestTimeout: integer read FRequestTimeout write FRequestTimeout default 30000;
    property PullTimeout: integer read FPullTimeout write FPullTimeout default 0;
    property MenuSections: TOllamaMenuSections read FMenuSections write SetMenuSections default [msPull, msServer, msModels, msConnect];

    property OnModelsRefreshed: TModelsRefreshedEvent read FOnModelsRefreshed write FOnModelsRefreshed;
    property OnError: TOllamaErrorEvent read FOnError write FOnError;
    property OnPullProgress: TPullProgressEvent read FOnPullProgress write FOnPullProgress;
    property OnConnecting: TConnectingEvent read FOnConnecting write FOnConnecting;
    property OnConnected: TConnectedEvent read FOnConnected write FOnConnected;
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
    // Master switch; when False no connection attempts are made and the menu is empty
    property Active;
    // When True, the model list is refreshed before each menu popup
    property AutoRefresh;
    // Connection timeout in milliseconds, applied while establishing the connection
    property ConnectionTimeout;
    // Timeout in milliseconds for regular API requests
    property RequestTimeout;
    // Reserved timeout in milliseconds for pull operations; 0 means no limit
    property PullTimeout;
    // Sections of the popup menu shown to the user; clear a flag to hide it
    property MenuSections;

    // Fired after the installed model list has been refreshed
    property OnModelsRefreshed;
    // Fired for any API or connection error; never raises
    property OnError;
    // Fired when pull progress changes (currently only start and finish)
    property OnPullProgress;
    // Fired before a background connection or refresh attempt begins
    property OnConnecting;
    // Fired after the model list has been successfully refreshed
    property OnConnected;
  end;

implementation

resourcestring
  rsPullModelMenu = 'Pull model...';
  rsServerMenu = 'Server...';
  rsStartMenu = 'Start';
  rsStopMenu = 'Stop';
  rsDeleteMenu = 'Delete';
  rsInfoMenu = 'Info...';
  rsLoadingModel = 'Loading %s...';
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

const
  TAG_PULL = 1;
  TAG_MODEL = 2;
  TAG_LOADING = 3;
  TAG_SEPARATOR = 4;
  TAG_CONNECTION = 5;
  TAG_SERVER = 6;

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
          JsonBody := Format('{"name":"%s","stream":false}', [FModelName]);
          FManager.ApiPost('/api/pull', JsonBody, FErrorKind, FErrorMsg);
        end;
        boStart:
        begin
          JsonBody := Format('{"model":"%s","prompt":"","keep_alive":%d,"stream":false}', [FModelName, FManager.KeepAlive]);
          FManager.ApiPost('/api/generate', JsonBody, FErrorKind, FErrorMsg);
        end;
        boStop:
        begin
          JsonBody := Format('{"model":"%s","prompt":"","keep_alive":0,"stream":false}', [FModelName]);
          FManager.ApiPost('/api/generate', JsonBody, FErrorKind, FErrorMsg);
        end;
        boRefresh:
        begin
          FTagsJson := FManager.ApiGet('/api/tags', FErrorKind, FErrorMsg);
          if FErrorKind = oekNone then
            FPsJson := FManager.ApiGet('/api/ps', FErrorKind, FErrorMsg);
        end;
      end;
    end;
  finally
    if Assigned(FManager) then
    begin
      try
        Synchronize(@DoFinish);
      except
        // Ignore - cannot reach the main thread during shutdown
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
    Mgr.BgFinished(FModelName, FErrorKind, FErrorMsg);
end;

{ TCustomOllamaManager }

constructor TCustomOllamaManager.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FBaseURL := 'http://localhost:11434';
  FKeepAlive := -1;
  FAutoRefresh := True;
  FConnectionTimeout := 5000;
  FRequestTimeout := 30000;
  FPullTimeout := 0;
  FMenuSections := [msPull, msServer, msModels, msConnect];
  FConnecting := False;
  FConnected := False;
  FActive := True;
  FConnectGen := 0;
  FShutdown := False;

  FInstalledModels := TStringList.Create;
  FRunningModels := TStringList.Create;
  FRunningDetails := TStringList.Create;
  FLoadingModels := TStringList.Create;
  FStartingModels := TStringList.Create;
  FStartingProgress := TStringList.Create;
  FStartSubItems := TStringList.Create;
  FActiveThreads := TList.Create;

  FInstalledModels.Sorted := True;
  FInstalledModels.Duplicates := dupIgnore;
  FRunningModels.Sorted := True;
  FRunningModels.Duplicates := dupIgnore;
  FLoadingModels.Sorted := True;
  FLoadingModels.Duplicates := dupIgnore;

  FRunningDetails.NameValueSeparator := '=';
  FStartingProgress.NameValueSeparator := '=';

  FProgressTimer := TTimer.Create(nil);
  FProgressTimer.Interval := 300;
  FProgressTimer.Enabled := False;
  FProgressTimer.OnTimer := @ProgressTimerTick;
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
  FreeAndNil(FRunningModels);
  FreeAndNil(FRunningDetails);
  FreeAndNil(FLoadingModels);
  FreeAndNil(FStartingModels);
  FreeAndNil(FStartingProgress);
  FreeAndNil(FStartSubItems);
  inherited Destroy;
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
    // User handler raised an exception; ignore so the manager stays consistent
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
    // Ignore user handler exceptions
  end;

  TOllamaBgThread.Create(Self, boRefresh, '', FConnectGen);
end;

procedure TCustomOllamaManager.ProcessRefreshData(const TagsJson, PsJson: string; Kind: TOllamaErrorKind;
  const ErrorMsg: string; AGen: integer);
var
  NewInstalled, NewRunning: TStringList;
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
    DoError(Kind, '', ErrorMsg);
    if Assigned(FPopupMenu) then
      BuildPopupMenu;
    Exit;
  end;

  NewInstalled := nil;
  NewRunning := nil;
  try
    try
      NewInstalled := ParseModels(TagsJson, nil);
      NewRunning := ParseModels(PsJson, FRunningDetails);
      FInstalledModels.Assign(NewInstalled);
      FRunningModels.Assign(NewRunning);
      FConnected := True;
      if Assigned(FOnConnected) then
      try
        FOnConnected(Self);
      except
        // Ignore user handler exceptions
      end;
      if Assigned(FOnModelsRefreshed) then
      try
        FOnModelsRefreshed(Self, FInstalledModels);
      except
        // Ignore user handler exceptions
      end;
    except
      // Defensive - should not normally happen
      FConnected := False;
    end;
  finally
    NewInstalled.Free;
    NewRunning.Free;
  end;

  // Refresh the popup so newly fetched models appear on the next open
  if Assigned(FPopupMenu) then
    BuildPopupMenu;
end;

procedure TCustomOllamaManager.BgFinished(const ModelName: string; Kind: TOllamaErrorKind; const ErrorMsg: string);
var
  Idx: integer;
begin
  if FShutdown then
    Exit;

  Idx := FLoadingModels.IndexOf(ModelName);
  if Idx >= 0 then
    FLoadingModels.Delete(Idx);

  Idx := FStartingModels.IndexOf(ModelName);
  if Idx >= 0 then
    FStartingModels.Delete(Idx);

  Idx := FStartingProgress.IndexOfName(ModelName);
  if Idx >= 0 then
    FStartingProgress.Delete(Idx);

  if Kind <> oekNone then
    DoError(Kind, ModelName, ErrorMsg);

  // Refresh the model list in the background
  BeginConnect;

  if (FStartingModels.Count = 0) and Assigned(FProgressTimer) then
    FProgressTimer.Enabled := False;
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

  // Invalidate any in-flight connection to the previous address so that
  // its result is ignored and the next attempt targets the new address
  Inc(FConnectGen);
  FConnecting := False;

  if Assigned(FPopupMenu) and FAutoRefresh then
    BeginConnect;
end;

procedure TCustomOllamaManager.SetPopupMenu(Value: TPopupMenu);
begin
  if FPopupMenu = Value then
    Exit;

  FStartSubItems.Clear;

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

  if Value then
    BeginConnect
  else
  begin
    // Invalidate any pending background result and drop connection state
    Inc(FConnectGen);
    FConnecting := False;
    FConnected := False;
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

  for I := FPopupMenu.Items.Count - 1 downto 0 do
  begin
    Item := FPopupMenu.Items[I];
    if (Item.Tag = TAG_PULL) or (Item.Tag = TAG_SERVER) or (Item.Tag = TAG_MODEL) or (Item.Tag = TAG_LOADING) or
      (Item.Tag = TAG_SEPARATOR) or (Item.Tag = TAG_CONNECTION) then
      FPopupMenu.Items.Delete(I);
  end;
end;

procedure TCustomOllamaManager.BuildPopupMenu;
var
  I, Pct, InsertPos: integer;
  ModelItem, SubItem: TMenuItem;
  ModelName: string;
  IsRunning, IsStarting: boolean;
  HasContentAbove: boolean;
  HasModels: boolean;
begin
  if not Assigned(FPopupMenu) then
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

    // Server item is always available while the manager is active
    if msServer in FMenuSections then
    begin
      ModelItem := TMenuItem.Create(FPopupMenu);
      ModelItem.Caption := rsServerMenu;
      ModelItem.Tag := TAG_SERVER;
      ModelItem.OnClick := @MenuServerClick;
      FPopupMenu.Items.Insert(InsertPos, ModelItem);
      Inc(InsertPos);
      HasContentAbove := True;
    end;

    if FConnected then
    begin
      if msModels in FMenuSections then
      begin
        HasModels := (FInstalledModels.Count > 0) or (FLoadingModels.Count > 0);

        // Separator between the Pull/Server items and the model list
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
            SubItem.Caption := rsInfoMenu;
            SubItem.Hint := ModelName;
            SubItem.OnClick := @MenuInfoClick;
            ModelItem.Add(SubItem);
          end;

          FPopupMenu.Items.Insert(InsertPos, ModelItem);
          Inc(InsertPos);
        end;

        // Loading models (pulling) grayed out
        for I := 0 to FLoadingModels.Count - 1 do
        begin
          ModelItem := TMenuItem.Create(FPopupMenu);
          ModelItem.Caption := Format(rsLoadingModel, [FLoadingModels[I]]);
          ModelItem.Tag := TAG_LOADING;
          ModelItem.Enabled := False;
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

  // Separator between the content block and Connect/Disconnect,
  // only when there is something above to separate from
  if HasContentAbove then
  begin
    ModelItem := TMenuItem.Create(FPopupMenu);
    ModelItem.Caption := '-';
    ModelItem.Tag := TAG_SEPARATOR;
    FPopupMenu.Items.Insert(InsertPos, ModelItem);
    Inc(InsertPos);
  end;

  // Connect item: turns into a disabled "Connecting..." label while a
  // connection attempt is in progress
  if msConnect in FMenuSections then
  begin
    ModelItem := TMenuItem.Create(FPopupMenu);
    ModelItem.Tag := TAG_CONNECTION;
    if FConnecting then
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
      // Invalid JSON - return whatever was parsed so far
    end;
  finally
    Data.Free;
  end;
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
              SL.Add(Format(rsInfoUnloadsAt, [ExpiresAt]));
            Found := True;
          end;
        except
          // Invalid cached JSON, treat as not loaded
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
  out Kind: TOllamaErrorKind; out ErrorMsg: string): string;
var
  Headers: TStringList;
  ResponseHeaders: TStringList;
  Cookies: TStringList;
  Err: boolean;
  SockErr: boolean;
  Tm: TTimeout;
  HTTP: THTTPSend;
  ContentType: string;
  ErrJSON: TJSONData;
  ErrTxt: string;
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
  Tm.Request := FRequestTimeout;

  if AMethod = wmPost then
    ContentType := 'application/json'
  else
    ContentType := '';

  try
    try
      Result := TNetwork.WebRequest(AMethod, FBaseURL + Endpoint, JsonBody, Headers, 'OllamaManager/1.0',
        ContentType, 'application/json', False, Default(TProxy), Tm, Cookies, ResponseHeaders, Err, HTTP);

      if Err then
      begin
        // Socket-level errors take priority: a failed connect can leave a
        // synthetic non-zero ResultCode (e.g. 5xx) that would be misclassified
        SockErr := (HTTP <> nil) and (HTTP.Sock <> nil) and (HTTP.Sock.LastError <> 0);
        if SockErr then
          Kind := oekConnection
        else if (HTTP <> nil) and (HTTP.ResultCode <> 0) then
          Kind := ClassifyHttp(HTTP.ResultCode)
        else
          Kind := oekConnection;

        // Try to extract the "error" field from a JSON error body, if any
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
              // Body looks like JSON but failed to parse; keep it as is
              ErrorMsg := Result;
            end;
          finally
            ErrJSON.Free;
          end;
        end
        else
          ErrorMsg := Result;

        if ErrorMsg = '' then
        begin
          if SockErr then
            ErrorMsg := HTTP.Sock.LastErrorDesc
          else if (HTTP <> nil) and (HTTP.ResultCode <> 0) then
            ErrorMsg := Format(rsHttpError, [HTTP.ResultCode, HTTP.ResultString])
          else
            ErrorMsg := rsConnectionError;
          if ErrorMsg = '' then
            ErrorMsg := rsConnectionError;
        end;
        Result := '';
      end;
    except
      on E: Exception do
      begin
        Kind := oekConnection;
        ErrorMsg := E.Message;
        Result := '';
      end;
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

function TCustomOllamaManager.ApiPost(const Endpoint, JsonBody: string; out Kind: TOllamaErrorKind; out ErrorMsg: string): string;
begin
  Result := DoRequest(wmPost, Endpoint, JsonBody, Kind, ErrorMsg);
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

procedure TCustomOllamaManager.PullModel(const ModelName: string);
begin
  if FShutdown then
    Exit;
  if FLoadingModels.IndexOf(ModelName) >= 0 then
    Exit;
  FLoadingModels.Add(ModelName);
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

  TOllamaBgThread.Create(Self, boStart, ModelName);
end;

procedure TCustomOllamaManager.StopModel(const ModelName: string);
begin
  if FShutdown then
    Exit;
  // Cloud models are not loaded locally, nothing to unload
  if IsCloudModel(ModelName) then
    Exit;
  TOllamaBgThread.Create(Self, boStop, ModelName);
end;

function TCustomOllamaManager.Generate(const ModelName, Prompt: string): string;
var
  JsonBody: string;
  Kind: TOllamaErrorKind;
  ErrMsg: string;
begin
  JsonBody := Format('{"model":"%s","prompt":"%s","keep_alive":%d,"stream":false}', [ModelName, Prompt.EscapeText, FKeepAlive]);
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
  JsonBody := Format('{"model":"%s","messages":[{"role":"user","content":"%s"}],"keep_alive":%d,"stream":false}',
    [ModelName, UserMessage.EscapeText, FKeepAlive]);
  Result := ApiPost('/api/chat', JsonBody, Kind, ErrMsg);
  if Kind <> oekNone then
  begin
    DoError(Kind, ModelName, ErrMsg);
    Result := '';
  end;
end;

end.
