//-----------------------------------------------------------------------------------
//  OllamaKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit AgentConfig;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, OllamaAgent, OllamaManager;

// Returns multi-line help text describing set/get/config commands and properties
function FormatAgentHelp: string;

// Returns multi-line list of current agent settings
function FormatAgentConfig(AAgent: TCustomOllamaAgent): string;

// Returns value of property, False with AError on unknown name or nil agent
function GetAgentProperty(AAgent: TCustomOllamaAgent; const AName: string; out AValue, AError: string): boolean;

// Sets property, False with AError on invalid name, value or nil agent
function SetAgentProperty(AAgent: TCustomOllamaAgent; const AName, AValue: string; out AError: string): boolean;

// Queries OllamaManager for available models, returns formatted list
function FormatModelsList(AAgent: TCustomOllamaAgent; out AError: string): string;

implementation

type
  TAgentPropertyKind = (apkString, apkInteger, apkBoolean, apkFeatureSet, apkText, apkHostList);

  TAgentPropertyInfo = record
    Name: string;
    Aliases: string;
    Kind: TAgentPropertyKind;
    Description: string;
  end;

const
  PROPERTIES: array[0..19] of TAgentPropertyInfo = (
    (Name: 'baseurl'; Aliases: 'url,ollama.url'; Kind: apkString;
    Description: 'Ollama server URL (example: http://localhost:11434)'),
    (Name: 'numctx'; Aliases: 'ollama.numctx'; Kind: apkInteger;
    Description: 'Context window override, 0 means use model default'),
    (Name: 'active'; Aliases: 'ollama.active'; Kind: apkBoolean;
    Description: 'Enable background refresh and connection'),
    (Name: 'model'; Aliases: 'modelname'; Kind: apkString;
    Description: 'Ollama model name (example: flint:40b)'),
    (Name: 'systemprompt'; Aliases: 'prompt,sysprompt'; Kind: apkText;
    Description: 'System message, use "set systemprompt from <file>" for multiline'),
    (Name: 'maxsteps'; Aliases: 'steps'; Kind: apkInteger;
    Description: 'Maximum iterations per run, 0 for unlimited'),
    (Name: 'timeout'; Aliases: 'requesttimeout'; Kind: apkInteger;
    Description: 'Per-request timeout in ms, 0 means use manager default'),
    (Name: 'streaming'; Aliases: ''; Kind: apkBoolean;
    Description: 'Stream content and thinking in real time'),
    (Name: 'tools'; Aliases: 'enabledtools'; Kind: apkFeatureSet;
    Description: 'Comma separated: filetools,exec,git,interactive,finish,web,all,none'),
    (Name: 'rootpath'; Aliases: 'root'; Kind: apkString;
    Description: 'Sandbox directory for file tools'),
    (Name: 'keephistory'; Aliases: 'history'; Kind: apkBoolean;
    Description: 'Persist messages between runs'),
    (Name: 'log'; Aliases: ''; Kind: apkBoolean;
    Description: 'Log every step to stderr'),
    (Name: 'web.searchurl'; Aliases: 'searchurl'; Kind: apkString;
    Description: 'URL template for web_search, use {query} placeholder'),
    (Name: 'web.useragent'; Aliases: 'useragent'; Kind: apkString;
    Description: 'User-Agent header for web requests'),
    (Name: 'web.timeout'; Aliases: 'web.requesttimeout'; Kind: apkInteger;
    Description: 'Timeout for web requests in ms'),
    (Name: 'web.maxbytes'; Aliases: 'web.maxresponsebytes'; Kind: apkInteger;
    Description: 'Maximum response body size for web tools'),
    (Name: 'web.striphtml'; Aliases: ''; Kind: apkBoolean;
    Description: 'Strip HTML tags from web responses'),
    (Name: 'web.blocklocalhost'; Aliases: ''; Kind: apkBoolean;
    Description: 'Block localhost in web tools'),
    (Name: 'web.blockprivateips'; Aliases: ''; Kind: apkBoolean;
    Description: 'Block private IPs in web tools'),
    (Name: 'web.allowedhosts'; Aliases: 'allowedhosts'; Kind: apkHostList;
    Description: 'Comma separated host whitelist, empty or "none" allows any host')
    );

type
  // Collects models and error events from OllamaManager on the main thread
  TModelListCollector = class
  public
    Models: TStringList;
    Done: boolean;
    Success: boolean;
    ErrorMsg: string;
    procedure OnModels(Sender: TObject; const AList: TStringList);
    procedure OnError(Sender: TObject; Kind: TOllamaErrorKind; const ModelName, Msg: string);
  end;

procedure TModelListCollector.OnModels(Sender: TObject; const AList: TStringList);
begin
  Models.Assign(AList);
  Success := True;
  Done := True;
end;

procedure TModelListCollector.OnError(Sender: TObject; Kind: TOllamaErrorKind; const ModelName, Msg: string);
begin
  if Kind = oekNone then
    Exit;
  ErrorMsg := Msg;
  Success := False;
  Done := True;
end;

// Looks up canonical property name by primary name or alias
function FindProperty(const AName: string; out ACanonical: string): boolean;
var
  I: integer;
  LowName, Alias: string;
begin
  Result := False;
  ACanonical := '';
  LowName := LowerCase(Trim(AName));
  if LowName = '' then
    Exit;
  for I := Low(PROPERTIES) to High(PROPERTIES) do
  begin
    if LowerCase(PROPERTIES[I].Name) = LowName then
    begin
      ACanonical := PROPERTIES[I].Name;
      Exit(True);
    end;
    if PROPERTIES[I].Aliases <> '' then
    begin
      Alias := ',' + LowerCase(PROPERTIES[I].Aliases) + ',';
      if Pos(',' + LowName + ',', Alias) > 0 then
      begin
        ACanonical := PROPERTIES[I].Name;
        Exit(True);
      end;
    end;
  end;
end;

// Parses on/off, true/false, yes/no, 1/0 to boolean
function ParseBoolValue(const AValue: string; out AResult: boolean): boolean;
var
  V: string;
begin
  V := LowerCase(Trim(AValue));
  if (V = 'on') or (V = 'true') or (V = 'yes') or (V = '1') then
  begin
    AResult := True;
    Result := True;
  end
  else if (V = 'off') or (V = 'false') or (V = 'no') or (V = '0') then
  begin
    AResult := False;
    Result := True;
  end
  else
    Result := False;
end;

// Formats boolean as on/off for display
function BoolToStrValue(AValue: boolean): string;
begin
  if AValue then
    Result := 'on'
  else
    Result := 'off';
end;

// Formats tool feature set as comma separated short names
function FormatFeatures(AFeatures: TAgentFeatures): string;
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
      Result := Parts.CommaText;
  finally
    Parts.Free;
  end;
end;

// Parses comma separated tool names into feature set
function ParseFeatures(const AValue: string; out AFeatures: TAgentFeatures; out AError: string): boolean;
var
  Parts: TStringList;
  I: integer;
  Name: string;
  HasNone, HasAll: boolean;
begin
  Result := False;
  AError := '';
  AFeatures := [];
  HasNone := False;
  HasAll := False;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ',';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := AValue;
    for I := 0 to Parts.Count - 1 do
    begin
      Name := LowerCase(Trim(Parts[I]));
      if Name = '' then
        Continue;
      if Name = 'none' then
        HasNone := True
      else if Name = 'all' then
        HasAll := True
      else if (Name = 'filetools') or (Name = 'file') or (Name = 'files') then
        Include(AFeatures, afFileTools)
      else if (Name = 'exec') or (Name = 'execcommand') or (Name = 'shell') or (Name = 'command') then
        Include(AFeatures, afExecCommand)
      else if Name = 'git' then
        Include(AFeatures, afGit)
      else if (Name = 'interactive') or (Name = 'ask') then
        Include(AFeatures, afInteractive)
      else if Name = 'finish' then
        Include(AFeatures, afFinish)
      else if (Name = 'web') or (Name = 'webtools') then
        Include(AFeatures, afWebTools)
      else
      begin
        AError := 'unknown tool: ' + Name;
        Exit;
      end;
    end;
    if HasNone and HasAll then
    begin
      AError := 'cannot mix "none" and "all"';
      Exit;
    end;
    if HasAll then
      AFeatures := [afFileTools, afExecCommand, afGit, afInteractive, afFinish, afWebTools];
    if HasNone then
      AFeatures := [];
    Result := True;
  finally
    Parts.Free;
  end;
end;

function FormatAgentHelp: string;
var
  I: integer;
  NameCol: string;
begin
  Result :=
    'Agent configuration:' + LineEnding + '  set <name> <value>     Set an agent property' + LineEnding +
    '  get <name>             Show current value of a property' + LineEnding +
    '  config                 Show all current agent settings' + LineEnding +
    '  help agent             Show this help (also just "?")' + LineEnding + LineEnding + 'Value formats:' +
    LineEnding + '  string    free text, use quotes if it contains spaces' + LineEnding +
    '  integer   whole number, 0 has special meaning where noted' + LineEnding + '  boolean   on, off, true, false, yes, no, 1, 0' +
    LineEnding + '  set       comma separated names, for example "filetools,exec,git"' + LineEnding +
    '  text      single line, or "from <file>" to load multiline file' + LineEnding +
    '  list      comma separated entries, "none" clears the list' + LineEnding + LineEnding + 'Properties:' + LineEnding;
  for I := Low(PROPERTIES) to High(PROPERTIES) do
  begin
    NameCol := '  ' + PROPERTIES[I].Name;
    while Length(NameCol) < 24 do
      NameCol := NameCol + ' ';
    Result := Result + NameCol + PROPERTIES[I].Description + LineEnding;
    if PROPERTIES[I].Aliases <> '' then
      Result := Result + '    aliases: ' + PROPERTIES[I].Aliases + LineEnding;
  end;
  Result := Result + LineEnding + 'Examples:' + LineEnding + '  set baseurl http://192.168.1.10:11434' +
    LineEnding + '  set numctx 8192' + LineEnding + '  set active on' + LineEnding + '  models' +
    LineEnding + '  set model qwen2.5:7b' + LineEnding + '  set maxsteps 40' + LineEnding +
    '  set streaming on' + LineEnding + '  set tools filetools,exec,web' + LineEnding + '  set tools all' +
    LineEnding + '  set systemprompt from prompt.txt' + LineEnding + '  set web.timeout 8000' + LineEnding +
    '  get tools' + LineEnding + '  config';
end;

function FormatAgentConfig(AAgent: TCustomOllamaAgent): string;
var
  T: TStringList;
  SysPreview, UserAgentPreview: string;

// Adds a padded name: value line to the output list
  procedure Add(const AName, AValue: string);
  var
    Col: string;
  begin
    Col := '  ' + AName;
    while Length(Col) < 24 do
      Col := Col + ' ';
    T.Add(Col + ': ' + AValue);
  end;

begin
  T := TStringList.Create;
  try
    T.Add('Agent Settings');
    if not Assigned(AAgent) then
    begin
      T.Add('  (no agent attached)');
      Result := T.Text;
      Exit;
    end;
    // Manager block first so the connection target is visible at the top
    if Assigned(AAgent.OllamaManager) then
    begin
      Add('baseurl', AAgent.OllamaManager.BaseURL);
      Add('numctx', IntToStr(AAgent.OllamaManager.NumCtx));
      Add('active', BoolToStrValue(AAgent.OllamaManager.Active));
      T.Add('');
    end
    else
    begin
      Add('baseurl', '(no OllamaManager)');
      T.Add('');
    end;
    Add('model', AAgent.ModelName);
    SysPreview := string(AAgent.SystemPrompt);
    if Length(SysPreview) > 80 then
      SysPreview := Copy(SysPreview, 1, 80) + '... (' + IntToStr(Length(AAgent.SystemPrompt)) + ' chars)'
    else if SysPreview = '' then
      SysPreview := '(empty)';
    Add('systemprompt', SysPreview);
    Add('maxsteps', IntToStr(AAgent.MaxSteps));
    if AAgent.RequestTimeout = 0 then
      Add('timeout', '0 (use manager default)')
    else
      Add('timeout', IntToStr(AAgent.RequestTimeout));
    Add('streaming', BoolToStrValue(AAgent.Streaming));
    Add('tools', FormatFeatures(AAgent.EnabledTools));
    if AAgent.RootPath = '' then
      Add('rootpath', '(process cwd)')
    else
      Add('rootpath', AAgent.RootPath);
    Add('keephistory', BoolToStrValue(AAgent.KeepHistory));
    Add('log', BoolToStrValue(AAgent.Log));
    T.Add('');
    T.Add('Web Options');
    Add('web.searchurl', AAgent.WebOptions.SearchUrl);
    UserAgentPreview := AAgent.WebOptions.UserAgent;
    if Length(UserAgentPreview) > 60 then
      UserAgentPreview := Copy(UserAgentPreview, 1, 60) + '...';
    Add('web.useragent', UserAgentPreview);
    Add('web.timeout', IntToStr(AAgent.WebOptions.RequestTimeout));
    Add('web.maxbytes', IntToStr(AAgent.WebOptions.MaxResponseBytes));
    Add('web.striphtml', BoolToStrValue(AAgent.WebOptions.StripHtml));
    Add('web.blocklocalhost', BoolToStrValue(AAgent.WebOptions.BlockLocalhost));
    Add('web.blockprivateips', BoolToStrValue(AAgent.WebOptions.BlockPrivateIPs));
    if AAgent.WebOptions.AllowedHosts.Count > 0 then
      Add('web.allowedhosts', AAgent.WebOptions.AllowedHosts.CommaText)
    else
      Add('web.allowedhosts', '(any host)');
    Result := T.Text;
  finally
    T.Free;
  end;
end;

function GetAgentProperty(AAgent: TCustomOllamaAgent; const AName: string; out AValue, AError: string): boolean;
var
  Canonical: string;
begin
  Result := False;
  AValue := '';
  AError := '';
  if not Assigned(AAgent) then
  begin
    AError := 'no agent attached';
    Exit;
  end;
  if not FindProperty(AName, Canonical) then
  begin
    AError := 'unknown property: ' + AName + ', use "help agent" for list';
    Exit;
  end;
  if Canonical = 'baseurl' then
  begin
    if not Assigned(AAgent.OllamaManager) then
    begin
      AError := 'agent has no OllamaManager';
      Exit;
    end;
    AValue := AAgent.OllamaManager.BaseURL;
  end
  else if Canonical = 'numctx' then
  begin
    if not Assigned(AAgent.OllamaManager) then
    begin
      AError := 'agent has no OllamaManager';
      Exit;
    end;
    AValue := IntToStr(AAgent.OllamaManager.NumCtx);
  end
  else if Canonical = 'active' then
  begin
    if not Assigned(AAgent.OllamaManager) then
    begin
      AError := 'agent has no OllamaManager';
      Exit;
    end;
    AValue := BoolToStrValue(AAgent.OllamaManager.Active);
  end
  else if Canonical = 'model' then
    AValue := AAgent.ModelName
  else if Canonical = 'systemprompt' then
    AValue := string(AAgent.SystemPrompt)
  else if Canonical = 'maxsteps' then
    AValue := IntToStr(AAgent.MaxSteps)
  else if Canonical = 'timeout' then
    AValue := IntToStr(AAgent.RequestTimeout)
  else if Canonical = 'streaming' then
    AValue := BoolToStrValue(AAgent.Streaming)
  else if Canonical = 'tools' then
    AValue := FormatFeatures(AAgent.EnabledTools)
  else if Canonical = 'rootpath' then
    AValue := AAgent.RootPath
  else if Canonical = 'keephistory' then
    AValue := BoolToStrValue(AAgent.KeepHistory)
  else if Canonical = 'log' then
    AValue := BoolToStrValue(AAgent.Log)
  else if Canonical = 'web.searchurl' then
    AValue := AAgent.WebOptions.SearchUrl
  else if Canonical = 'web.useragent' then
    AValue := AAgent.WebOptions.UserAgent
  else if Canonical = 'web.timeout' then
    AValue := IntToStr(AAgent.WebOptions.RequestTimeout)
  else if Canonical = 'web.maxbytes' then
    AValue := IntToStr(AAgent.WebOptions.MaxResponseBytes)
  else if Canonical = 'web.striphtml' then
    AValue := BoolToStrValue(AAgent.WebOptions.StripHtml)
  else if Canonical = 'web.blocklocalhost' then
    AValue := BoolToStrValue(AAgent.WebOptions.BlockLocalhost)
  else if Canonical = 'web.blockprivateips' then
    AValue := BoolToStrValue(AAgent.WebOptions.BlockPrivateIPs)
  else if Canonical = 'web.allowedhosts' then
  begin
    if AAgent.WebOptions.AllowedHosts.Count = 0 then
      AValue := 'none'
    else
      AValue := AAgent.WebOptions.AllowedHosts.CommaText;
  end
  else
  begin
    AError := 'property not readable: ' + Canonical;
    Exit;
  end;
  Result := True;
end;

function SetAgentProperty(AAgent: TCustomOllamaAgent; const AName, AValue: string; out AError: string): boolean;
var
  Canonical, Value, FirstWord, RestValue: string;
  P, IntVal: integer;
  BoolVal: boolean;
  FeatVal: TAgentFeatures;
  HostParts: TStringList;
begin
  Result := False;
  AError := '';
  if not Assigned(AAgent) then
  begin
    AError := 'no agent attached';
    Exit;
  end;
  if not FindProperty(AName, Canonical) then
  begin
    AError := 'unknown property: ' + AName + ', use "help agent" for list';
    Exit;
  end;
  Value := Trim(AValue);
  // Strip surrounding quotes for string values
  if (Length(Value) >= 2) and (Value[1] = '"') and (Value[Length(Value)] = '"') then
    Value := Copy(Value, 2, Length(Value) - 2);

  if Canonical = 'baseurl' then
  begin
    if not Assigned(AAgent.OllamaManager) then
    begin
      AError := 'agent has no OllamaManager';
      Exit;
    end;
    if Trim(Value) = '' then
    begin
      AError := 'baseurl cannot be empty';
      Exit;
    end;
    AAgent.OllamaManager.BaseURL := Value;
  end
  else if Canonical = 'numctx' then
  begin
    if not Assigned(AAgent.OllamaManager) then
    begin
      AError := 'agent has no OllamaManager';
      Exit;
    end;
    if not TryStrToInt(Value, IntVal) or (IntVal < 0) then
    begin
      AError := 'numctx must be a non-negative integer';
      Exit;
    end;
    AAgent.OllamaManager.NumCtx := IntVal;
  end
  else if Canonical = 'active' then
  begin
    if not Assigned(AAgent.OllamaManager) then
    begin
      AError := 'agent has no OllamaManager';
      Exit;
    end;
    if not ParseBoolValue(Value, BoolVal) then
    begin
      AError := 'active must be on/off, true/false, yes/no';
      Exit;
    end;
    AAgent.OllamaManager.Active := BoolVal;
  end
  else if Canonical = 'model' then
    AAgent.ModelName := Value
  else if Canonical = 'systemprompt' then
  begin
    // Support "from <file>" form for multiline prompts
    P := Pos(' ', Value);
    if P > 0 then
    begin
      FirstWord := LowerCase(Copy(Value, 1, P - 1));
      RestValue := Trim(Copy(Value, P + 1, MaxInt));
    end
    else
    begin
      FirstWord := LowerCase(Value);
      RestValue := '';
    end;
    if FirstWord = 'from' then
    begin
      // Strip quotes around the filename
      if (Length(RestValue) >= 2) and (RestValue[1] = '"') and (RestValue[Length(RestValue)] = '"') then
        RestValue := Copy(RestValue, 2, Length(RestValue) - 2);
      if RestValue = '' then
      begin
        AError := 'usage: set systemprompt from <filename>';
        Exit;
      end;
      if not FileExists(RestValue) then
      begin
        AError := 'file not found: ' + RestValue;
        Exit;
      end;
      try
        with TStringList.Create do
        try
          LoadFromFile(RestValue);
          AAgent.SystemPrompt := Text;
        finally
          Free;
        end;
      except
        on E: Exception do
        begin
          AError := 'read error: ' + E.Message;
          Exit;
        end;
      end;
    end
    else
      AAgent.SystemPrompt := Value;
  end
  else if Canonical = 'maxsteps' then
  begin
    if not TryStrToInt(Value, IntVal) or (IntVal < 0) then
    begin
      AError := 'maxsteps must be a non-negative integer';
      Exit;
    end;
    AAgent.MaxSteps := IntVal;
  end
  else if Canonical = 'timeout' then
  begin
    if not TryStrToInt(Value, IntVal) or (IntVal < 0) then
    begin
      AError := 'timeout must be a non-negative integer';
      Exit;
    end;
    AAgent.RequestTimeout := IntVal;
  end
  else if Canonical = 'streaming' then
  begin
    if not ParseBoolValue(Value, BoolVal) then
    begin
      AError := 'streaming must be on/off, true/false, yes/no';
      Exit;
    end;
    AAgent.Streaming := BoolVal;
  end
  else if Canonical = 'tools' then
  begin
    if not ParseFeatures(Value, FeatVal, AError) then
      Exit;
    AAgent.EnabledTools := FeatVal;
  end
  else if Canonical = 'rootpath' then
    AAgent.RootPath := Value
  else if Canonical = 'keephistory' then
  begin
    if not ParseBoolValue(Value, BoolVal) then
    begin
      AError := 'keephistory must be on/off, true/false, yes/no';
      Exit;
    end;
    AAgent.KeepHistory := BoolVal;
  end
  else if Canonical = 'log' then
  begin
    if not ParseBoolValue(Value, BoolVal) then
    begin
      AError := 'log must be on/off, true/false, yes/no';
      Exit;
    end;
    AAgent.Log := BoolVal;
  end
  else if Canonical = 'web.searchurl' then
    AAgent.WebOptions.SearchUrl := Value
  else if Canonical = 'web.useragent' then
    AAgent.WebOptions.UserAgent := Value
  else if Canonical = 'web.timeout' then
  begin
    if not TryStrToInt(Value, IntVal) or (IntVal < 0) then
    begin
      AError := 'web.timeout must be a non-negative integer';
      Exit;
    end;
    AAgent.WebOptions.RequestTimeout := IntVal;
  end
  else if Canonical = 'web.maxbytes' then
  begin
    if not TryStrToInt(Value, IntVal) or (IntVal <= 0) then
    begin
      AError := 'web.maxbytes must be a positive integer';
      Exit;
    end;
    AAgent.WebOptions.MaxResponseBytes := IntVal;
  end
  else if Canonical = 'web.striphtml' then
  begin
    if not ParseBoolValue(Value, BoolVal) then
    begin
      AError := 'web.striphtml must be on/off, true/false, yes/no';
      Exit;
    end;
    AAgent.WebOptions.StripHtml := BoolVal;
  end
  else if Canonical = 'web.blocklocalhost' then
  begin
    if not ParseBoolValue(Value, BoolVal) then
    begin
      AError := 'web.blocklocalhost must be on/off, true/false, yes/no';
      Exit;
    end;
    AAgent.WebOptions.BlockLocalhost := BoolVal;
  end
  else if Canonical = 'web.blockprivateips' then
  begin
    if not ParseBoolValue(Value, BoolVal) then
    begin
      AError := 'web.blockprivateips must be on/off, true/false, yes/no';
      Exit;
    end;
    AAgent.WebOptions.BlockPrivateIPs := BoolVal;
  end
  else if Canonical = 'web.allowedhosts' then
  begin
    if (LowerCase(Value) = 'none') or (Value = '') then
      AAgent.WebOptions.AllowedHosts.Clear
    else
    begin
      HostParts := TStringList.Create;
      try
        HostParts.Delimiter := ',';
        HostParts.StrictDelimiter := True;
        HostParts.DelimitedText := Value;
        AAgent.WebOptions.AllowedHosts.Assign(HostParts);
      finally
        HostParts.Free;
      end;
    end;
  end
  else
  begin
    AError := 'property not writable: ' + Canonical;
    Exit;
  end;
  Result := True;
end;

function FormatModelsList(AAgent: TCustomOllamaAgent; out AError: string): string;
var
  Collector: TModelListCollector;
  OldModelsHandler: TModelsRefreshedEvent;
  OldErrorHandler: TOllamaErrorEvent;
  StartTime: QWord;
  Timeout: integer;
  T: TStringList;
  I: integer;
begin
  Result := '';
  AError := '';
  if not Assigned(AAgent) then
  begin
    AError := 'no agent attached';
    Exit;
  end;
  if not Assigned(AAgent.OllamaManager) then
  begin
    AError := 'agent has no OllamaManager';
    Exit;
  end;
  if not AAgent.OllamaManager.Active then
  begin
    AError := 'OllamaManager is inactive, enable with "set active on"';
    Exit;
  end;

  Collector := TModelListCollector.Create;
  try
    Collector.Models := TStringList.Create;
    Collector.Models.Sorted := True;
    Collector.Models.Duplicates := dupIgnore;
    Collector.Done := False;
    Collector.Success := False;
    Collector.ErrorMsg := '';

    // Save existing handlers so host callbacks are not lost
    OldModelsHandler := AAgent.OllamaManager.OnModelsRefreshed;
    OldErrorHandler := AAgent.OllamaManager.OnError;
    AAgent.OllamaManager.OnModelsRefreshed := @Collector.OnModels;
    AAgent.OllamaManager.OnError := @Collector.OnError;
    try
      AAgent.OllamaManager.RefreshModels;
      Timeout := AAgent.OllamaManager.RequestTimeout;
      if Timeout <= 0 then
        Timeout := 15000;
      StartTime := GetTickCount64;
      // Pump the sync queue until event arrives or timeout expires
      while (not Collector.Done) and (GetTickCount64 - StartTime < QWord(Timeout)) do
        CheckSynchronize(50);
    finally
      AAgent.OllamaManager.OnModelsRefreshed := OldModelsHandler;
      AAgent.OllamaManager.OnError := OldErrorHandler;
    end;

    if not Collector.Done then
    begin
      AError := 'timeout waiting for models list from ' + AAgent.OllamaManager.BaseURL;
      Exit;
    end;
    if not Collector.Success then
    begin
      if Collector.ErrorMsg = '' then
        AError := 'failed to fetch models'
      else
        AError := Collector.ErrorMsg;
      Exit;
    end;

    T := TStringList.Create;
    try
      T.Add('Available models (' + IntToStr(Collector.Models.Count) + ') at ' + AAgent.OllamaManager.BaseURL + ':');
      if Collector.Models.Count = 0 then
        T.Add('  (no models installed)')
      else
        for I := 0 to Collector.Models.Count - 1 do
        begin
          // Mark the currently selected model
          if Collector.Models[I] = AAgent.ModelName then
            T.Add('  * ' + Collector.Models[I])
          else
            T.Add('    ' + Collector.Models[I]);
        end;
      T.Add('');
      T.Add('Use "set model <name>" to switch, * marks current selection');
      Result := T.Text;
    finally
      T.Free;
    end;
  finally
    Collector.Models.Free;
    Collector.Free;
  end;
end;

end.
