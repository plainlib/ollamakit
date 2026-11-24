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

// Returns short help text with essential commands and shortcuts
function FormatShortHelp: string;

// Returns full help text with all commands, settings, examples and shortcuts
function FormatFullHelp(Agent: boolean; Term: boolean; Shortcuts: boolean): string;

// Returns help text for Ollama server management commands
function FormatOllamaHelp: string;

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
    // True when the property is not stored in the settings file
    Runtime: boolean;
  end;

const
  // Short display names for tool features, index must match TAgentFeature
  FEATURE_SHORT: array[TAgentFeature] of string = (
    'filetools', 'exec', 'git', 'interactive', 'finish', 'web'
    );
  // Comma separated aliases for each tool, empty when no alias exists
  FEATURE_ALIASES: array[TAgentFeature] of string = (
    'file,files', 'execcommand,shell,command', '', 'ask', '', 'webtools'
    );

  PROPERTIES: array[0..30] of TAgentPropertyInfo = (
    // OllamaManager settings, saved
    (Name: 'baseurl'; Aliases: 'url,ollama.url'; Kind: apkString;
    Description: 'Ollama server URL (example: http://localhost:11434)'; Runtime: False),
    (Name: 'keepalive'; Aliases: 'ollama.keepalive'; Kind: apkInteger;
    Description: 'How long to keep model loaded, -1 forever, 0 unload'; Runtime: False),
    (Name: 'autorefresh'; Aliases: 'ollama.autorefresh'; Kind: apkBoolean;
    Description: 'Refresh model list on popup menu'; Runtime: False),
    (Name: 'connectiontimeout'; Aliases: 'ollama.connectiontimeout'; Kind: apkInteger;
    Description: 'Connection timeout in ms'; Runtime: False),
    (Name: 'manager.timeout'; Aliases: 'ollama.timeout,manager.timeout'; Kind: apkInteger;
    Description: 'OllamaManager default request timeout in ms'; Runtime: False),
    (Name: 'pulltimeout'; Aliases: 'ollama.pulltimeout'; Kind: apkInteger;
    Description: 'Pull operation timeout in ms, 0 means no limit'; Runtime: False),
    (Name: 'modeltimeout'; Aliases: 'ollama.modeltimeout'; Kind: apkInteger;
    Description: 'Model load and unload timeout in ms'; Runtime: False),
    // OllamaManager runtime-only
    (Name: 'numctx'; Aliases: 'ollama.numctx'; Kind: apkInteger;
    Description: 'Context window override, 0 means use model default'; Runtime: True),
    (Name: 'active'; Aliases: 'ollama.active'; Kind: apkBoolean;
    Description: 'Enable background refresh and connection'; Runtime: True),
    // OllamaAgent settings, saved
    (Name: 'model'; Aliases: 'modelname'; Kind: apkString;
    Description: 'Ollama model name (example: flint:40b)'; Runtime: False),
    (Name: 'systemprompt'; Aliases: 'prompt,sysprompt'; Kind: apkText;
    Description: 'System message, use "set systemprompt from <file>" for multiline'; Runtime: False),
    (Name: 'maxsteps'; Aliases: 'steps'; Kind: apkInteger;
    Description: 'Maximum iterations per run, 0 for unlimited'; Runtime: False),
    (Name: 'timeout'; Aliases: 'agent.timeout,requesttimeout'; Kind: apkInteger;
    Description: 'Per-request timeout in ms, 0 means use manager default'; Runtime: False),
    (Name: 'streaming'; Aliases: ''; Kind: apkBoolean;
    Description: 'Stream content and thinking in real time'; Runtime: False),
    (Name: 'tools'; Aliases: 'enabledtools'; Kind: apkFeatureSet;
    Description: 'Comma separated: filetools, exec, git, interactive, finish, web, all, none'; Runtime: False),
    (Name: 'rootpath'; Aliases: 'root'; Kind: apkString;
    Description: 'Sandbox directory for file tools'; Runtime: False),
    (Name: 'keephistory'; Aliases: 'persist'; Kind: apkBoolean;
    Description: 'Persist messages between runs'; Runtime: False),
    (Name: 'log'; Aliases: ''; Kind: apkBoolean;
    Description: 'Log every step to stderr'; Runtime: False),
    (Name: 'logtoolresult'; Aliases: ''; Kind: apkBoolean;
    Description: 'Log tool results'; Runtime: False),
    (Name: 'loadagentsmd'; Aliases: ''; Kind: apkBoolean;
    Description: 'Load AGENTS.md instructions'; Runtime: False),
    (Name: 'agentsfilename'; Aliases: ''; Kind: apkString;
    Description: 'Instructions file name'; Runtime: False),
    (Name: 'allowaccesstosystem'; Aliases: ''; Kind: apkBoolean;
    Description: 'Allow file access outside RootPath'; Runtime: False),
    (Name: 'blocksensitivefiles'; Aliases: ''; Kind: apkBoolean;
    Description: 'Block access to sensitive files'; Runtime: False),
    // Web options, saved
    (Name: 'web.searchurl'; Aliases: 'searchurl'; Kind: apkString;
    Description: 'URL template for web_search, use {query} placeholder'; Runtime: False),
    (Name: 'web.useragent'; Aliases: 'useragent'; Kind: apkString;
    Description: 'User-Agent header for web requests'; Runtime: False),
    (Name: 'web.timeout'; Aliases: 'web.requesttimeout'; Kind: apkInteger;
    Description: 'Timeout for web requests in ms'; Runtime: False),
    (Name: 'web.maxbytes'; Aliases: 'web.maxresponsebytes'; Kind: apkInteger;
    Description: 'Maximum response body size for web tools'; Runtime: False),
    (Name: 'web.striphtml'; Aliases: ''; Kind: apkBoolean;
    Description: 'Strip HTML tags from web responses'; Runtime: False),
    (Name: 'web.blocklocalhost'; Aliases: ''; Kind: apkBoolean;
    Description: 'Block localhost in web tools'; Runtime: False),
    (Name: 'web.blockprivateips'; Aliases: ''; Kind: apkBoolean;
    Description: 'Block private IPs in web tools'; Runtime: False),
    (Name: 'web.allowedhosts'; Aliases: 'allowedhosts'; Kind: apkHostList;
    Description: 'Comma separated host whitelist, empty or "none" allows any host'; Runtime: False)
    );

type
  // Collects models and error events from OllamaManager on the main thread
  TModelListCollector = class
  public
    Models: TStringList;
    Done: boolean;
    Success: boolean;
    ErrorMsg: string;
    procedure OnModels(Sender: TObject; const OldModels, NewModels: TStringList);
    procedure OnError(Sender: TObject; Kind: TOllamaErrorKind; const ModelName, Msg: string);
  end;

procedure TModelListCollector.OnModels(Sender: TObject; const OldModels, NewModels: TStringList);
begin
  Models.Assign(NewModels);
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

// Resolves a short tool name or alias to a feature, False when unknown
function FindFeature(const AName: string; out AFeature: TAgentFeature): boolean;
var
  F: TAgentFeature;
  Alias: string;
begin
  Result := False;
  AFeature := afFileTools;
  for F := Low(TAgentFeature) to High(TAgentFeature) do
  begin
    if FEATURE_SHORT[F] = AName then
    begin
      AFeature := F;
      Exit(True);
    end;
    if FEATURE_ALIASES[F] <> '' then
    begin
      Alias := ',' + FEATURE_ALIASES[F] + ',';
      if Pos(',' + AName + ',', Alias) > 0 then
      begin
        AFeature := F;
        Exit(True);
      end;
    end;
  end;
end;

// Formats tool feature set as comma separated short names
function FormatFeatures(AFeatures: TAgentFeatures): string;
var
  Parts: TStringList;
  F: TAgentFeature;
begin
  Parts := TStringList.Create;
  try
    for F := Low(TAgentFeature) to High(TAgentFeature) do
      if F in AFeatures then
        Parts.Add(FEATURE_SHORT[F]);
    if Parts.Count = 0 then
      Result := 'none'
    else
      Result := StringReplace(Parts.CommaText, ',', ', ', [rfReplaceAll]);
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
  F: TAgentFeature;
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
      else if not FindFeature(Name, F) then
      begin
        AError := 'unknown tool: ' + Name;
        Exit;
      end
      else
        Include(AFeatures, F);
    end;
    if HasNone and HasAll then
    begin
      AError := 'cannot mix "none" and "all"';
      Exit;
    end;
    if HasNone and (AFeatures <> []) then
    begin
      AError := '"none" cannot be combined with other tools';
      Exit;
    end;
    if HasAll then
      for F := Low(TAgentFeature) to High(TAgentFeature) do
        Include(AFeatures, F);
    if HasNone then
      AFeatures := [];
    Result := True;
  finally
    Parts.Free;
  end;
end;

function FormatShortHelp: string;
var
  T: TStringList;

// Adds a section header with a leading blank line
  procedure Header(const AText: string);
  begin
    T.Add('');
    T.Add(AText);
  end;

  // Adds an aligned command or shortcut row
  procedure Row(const AName, ADesc: string);
  var
    Pad: string;
  begin
    Pad := '  ' + AName;
    while Length(Pad) < 34 do
      Pad := Pad + ' ';
    T.Add(Pad + ADesc);
  end;

begin
  T := TStringList.Create;
  try
    Header('Commands');
    Row('cd [path]', 'change working directory');
    Row('pwd', 'show working directory');
    Row('cls / clear', 'clear the current chat');
    Row('new', 'start a new chat');
    Row('exit / quit', 'exit the console');
    Row('set <name> <value>', 'change a property');
    Row('get <name>', 'inspect a property');
    Row('set chat <name>', 'switch to a chat by name');
    Row('get chat', 'list all chats');
    Row('set chatname <name>', 'rename the active chat');
    Row('get chatname', 'show active chat name');
    Row('set chatprompt <text>', 'set additional chat instructions');
    Row('get chatprompt', 'show additional chat instructions');
    Row('config', 'show current settings');
    Row('models', 'list available models');
    Row('history', 'show command history');

    Header('Shortcuts');
    Row('Ctrl+N', 'Start a new chat');
    Row('Ctrl+Left/Right', 'Switch between chats');
    Row('Ctrl+Shift+Del', 'Delete the active chat');
    Row('Ctrl+Backspace', 'Remove the last input and result');
    Row('Ctrl+Home/End', 'Move to input start/end');
    Row('Ctrl+Shift+Up/Down', 'First/last history entry');
    Row('Alt+PageUp/Down', 'Navigate between user messages');
    Row('Shift+PageUp/Down', 'Scroll output by one line');
    Row('PageUp/Down', 'Scroll output by page');

    Header('Type "help" for the full help.');
    Row('help agent', 'agent full help');
    Row('help term', 'terminal full help');
    Row('help shortcuts', 'shortcuts full help');
    Row('ollama help', 'model management commands');
    Result := T.Text;
  finally
    T.Free;
  end;
end;

function FormatFullHelp(Agent: boolean; Term: boolean; Shortcuts: boolean): string;
var
  T: TStringList;

// Adds a section header with a leading blank line
  procedure Header(const AText: string);
  begin
    T.Add('');
    T.Add(AText);
  end;

  // Adds an aligned property row
  procedure Row(const AName, ADesc: string);
  var
    Pad: string;
  begin
    Pad := '  ' + AName;
    while Length(Pad) < 34 do
      Pad := Pad + ' ';
    T.Add(Pad + ADesc);
  end;

begin
  T := TStringList.Create;
  try
    if Agent then
    begin
      Header('Ollama');
      Row('baseurl', 'server URL, e.g. http://localhost:11434');
      Row('keepalive', 'keep loaded, -1 forever, 0 unload');
      Row('autorefresh', 'refresh model list on popup');
      Row('connectiontimeout', 'connect timeout ms');
      Row('manager.timeout', 'default request timeout ms');
      Row('pulltimeout', 'pull timeout ms, 0 = none');
      Row('modeltimeout', 'model load/unload timeout ms');
      Row('context', 'context window in tokens, 0 = Ollama default');
      Row('active', 'background refresh and connection');

      Header('Agent');
      Row('model', 'model name, e.g. flint:40b');
      Row('systemprompt', 'message text or "from <file>"');
      Row('maxsteps', 'iterations per run, 0 = unlimited');
      Row('timeout', 'request timeout ms, 0 = manager');
      Row('streaming', 'stream content in real time');
      Row('tools', 'filetools exec git interactive finish web');
      Row('rootpath', 'sandbox directory for file tools');
      Row('keephistory', 'persist messages between runs');
      Row('log', 'log every step to stderr');
      Row('logtoolresult', 'log tool results');
      Row('loadagentsmd', 'load AGENTS.md instructions');
      Row('agentsfilename', 'instructions file name');
      Row('allowaccesstosystem', 'allow access outside RootPath');
      Row('blocksensitivefiles', 'block sensitive files');

      Header('Web');
      Row('web.searchurl', 'template, {query} placeholder');
      Row('web.useragent', 'User-Agent header');
      Row('web.timeout', 'request timeout ms');
      Row('web.maxbytes', 'response body cap');
      Row('web.striphtml', 'strip HTML tags');
      Row('web.blocklocalhost', 'block localhost');
      Row('web.blockprivateips', 'block private IPv4');
      Row('web.allowedhosts', 'whitelist, "none" = any');
    end;
    if Term then
    begin
      Header('Terminal settings');
      Row('term.path', 'working directory');
      Row('term.shell', 'executable, e.g. cmd.exe or pwsh.exe');
      Row('term.showthinking', 'on|off, show agent reasoning text');
      Row('term.showagentstats', 'on|off, show final agent run statistics');
      Row('term.agentstatsformat', 'completion statistics template, supports placeholders');
      Row('term.commandtimeout', 'ms, user command timeout, 0 = none');
      Row('term.maxcapturebytes', 'captured output limit per command');
      Row('term.agentcommandtimeout', 'agent command timeout ms, 0 = unlimited');

      Header('Terminal colors');
      Row('term.color', '<role> [foreground|background] <color>');
      Row('get term.color', 'show the current color scheme');
      Row('defaulttext', 'regular terminal output');
      Row('thinkingtext', 'agent thinking text');
      Row('welcomebadge', 'welcome banner');
      Row('thinkingbadge', 'thinking label');
      Row('toolbadge', 'tool call label');
      Row('errorbadge', 'error messages');
      Row('warnbadge', 'warning messages');
      Row('agentdonebadge', 'successful agent completion statistics');
      Row('promptinput', 'user prompt and input');
      Row('log', 'agent log messages');
      Row('markdown.marker', 'Markdown delimiters');
      Row('markdown.bold', 'bold text');
      Row('markdown.italic', 'italic text');
      Row('markdown.strikethrough', 'strikethrough text');
      Row('markdown.inlinecode', 'inline code');
      Row('markdown.fencedcode', 'fenced code block text');
      Row('markdown.highlight', 'highlighted text');
      Row('markdown.heading', 'heading text');
      Row('markdown.quote', 'blockquote text');
      Row('markdown.listmarker', 'list markers');
      Row('colors', 'black red green yellow blue magenta cyan gray');
      Row('', 'darkgray lightred lightgreen lightyellow lightblue');
      Row('', 'lightmagenta lightcyan white');
      Row('', 'defaulttext and thinkingtext use a single color');
      Row('', 'other roles support foreground and background');
    end;

    if Agent or Term then
    begin
      Header('Values');
      Row('boolean', 'on off true false yes no 1 0');
      Row('list', 'comma separated, "none" clears');
      Row('text', 'single line, or "from <file>"');
      Row('runtime', 'context and active are not saved');
    end;

    if Agent or Term then
      Header('Examples');
    if Agent then
    begin
      Row('', 'set baseurl http://192.168.1.10:11434');
      Row('', 'set model qwen2.5:7b');
      Row('', 'set tools filetools, exec');
      Row('', 'set systemprompt from prompt.txt');
      Row('', 'get chat');
      Row('', 'set chat My project');
      Row('', 'set chatname Main project');
      Row('', 'get chatname');
      Row('', 'set chatprompt You are an expert Pascal developer');
      Row('', 'get chatprompt');
      Row('', 'get tools');
    end;
    if Term then
    begin
      Row('', 'set term.agentstatsformat "[DONE] {duration} | {ops} ops"');
      Row('', 'set term.agentstatsformat "{duration} - Tools: {tool_count}, Thinking: {thinking_count}, Answers: {answer_count}"');
      Row('', 'set term.color defaulttext white');
      Row('', 'set term.color thinkingtext gray');
      Row('', 'set term.color toolbadge background blue');
      Row('', 'set term.color errorbadge foreground white');
      Row('', 'set term.color agentdonebadge background yellow');
      Row('', 'set term.color agentdonebadge foreground black');
      Row('', 'set term.color markdown.marker darkgray');
      Row('', 'set term.color markdown.bold white');
      Row('', 'set term.color markdown.inlinecode lightgreen');
    end;

    if Shortcuts then
    begin
      Header('Keyboard shortcuts');
      Row('Enter', 'submit input');
      Row('Shift+Enter', 'insert a new line');
      Row('Ctrl+Enter', 'insert a new line');
      Row('Ctrl+N', 'start a new chat');
      Row('Ctrl+Left/Right', 'switch between chats');
      Row('Ctrl+Shift+Del', 'delete the active chat');
      Row('Ctrl+Backspace', 'remove the last input and result');
      Row('Ctrl+Up/Down', 'navigate command history');
      Row('Ctrl+Shift+Up/Down', 'select first/last history entry');
      Row('Ctrl+Home/End', 'move to input start/end');
      Row('Alt+PageUp/Down', 'navigate between user messages');
      Row('Shift+PageUp/Down', 'scroll output by one line');
      Row('PageUp/PageDown', 'scroll output by page');
      Row('Ctrl+Delete', 'delete the current history entry');
      Row('Ctrl+A', 'select input or copy chat when empty');
      Row('Ctrl+C', 'copy selection or cancel current input');
      Row('Ctrl+V', 'paste from clipboard');
      Row('Shift+Left/Right', 'select text');
      Row('Left/Right', 'move cursor');
      Row('Up/Down', 'move vertically or navigate history');
      Row('Home/End', 'move to line start/end');
      Row('Escape', 'clear current input');
    end;

    Header('Type "help" for the full help.');
    if not Agent then
      Row('help agent', 'agent full help');
    if not Term then
      Row('help term', 'terminal full help');
    if not Shortcuts then
      Row('help shortcuts', 'shortcuts full help');
    Row('ollama help', 'model management commands');
    Row('h / ?', 'show short help');

    Result := T.Text;
  finally
    T.Free;
  end;
end;

function FormatOllamaHelp: string;
var
  T: TStringList;

// Adds a section header with a leading blank line
  procedure Header(const AText: string);
  begin
    if T.Count > 0 then
      T.Add('');
    T.Add(AText);
  end;

  // Adds an aligned command row
  procedure Row(const ACmd, ADesc: string);
  var
    Pad: string;
  begin
    Pad := '  ' + ACmd;
    while Length(Pad) < 34 do
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
    Row('ollama context', 'show current context window');
    Row('ollama context <tokens>', 'set context window, 0 = default');
    Row('ollama help', 'this help');

    Header('Context examples');
    Row('ollama context', 'show current context window');
    Row('ollama context 8192', 'set 8K tokens');
    Row('ollama context 32768', 'set 32K tokens');
    Row('ollama context 262144', 'set 256K tokens');
    Row('ollama context 0', 'use Ollama default');
    Row('', 'Values are specified in tokens, not thousands');

    T.Add('');
    T.Add('  Uses baseurl, never invokes the shell');
    T.Add('');
    Result := T.Text;
  finally
    T.Free;
  end;
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
    while Length(Col) < 34 do
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
    // OllamaManager block, only fields that are saved to disk
    if Assigned(AAgent.OllamaManager) then
    begin
      if AAgent.OllamaManager.BaseURL = '' then
        Add('baseurl', '(empty)')
      else
        Add('baseurl', AAgent.OllamaManager.BaseURL);
      Add('keepalive', IntToStr(AAgent.OllamaManager.KeepAlive));
      Add('autorefresh', BoolToStrValue(AAgent.OllamaManager.AutoRefresh));
      Add('connectiontimeout', IntToStr(AAgent.OllamaManager.ConnectionTimeout));
      Add('manager.timeout', IntToStr(AAgent.OllamaManager.RequestTimeout));
      Add('pulltimeout', IntToStr(AAgent.OllamaManager.PullTimeout));
      Add('modeltimeout', IntToStr(AAgent.OllamaManager.ModelTimeout));
      T.Add('');
    end
    else
    begin
      Add('baseurl', '(no OllamaManager)');
      T.Add('');
    end;
    // OllamaAgent block
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
    Add('keephistory', BoolToStrValue(AAgent.KeepHistory));
    Add('log', BoolToStrValue(AAgent.Log));
    Add('logtoolresult', BoolToStrValue(AAgent.LogToolResult));
    Add('loadagentsmd', BoolToStrValue(AAgent.LoadAgentsMd));
    Add('agentsfilename', AAgent.AgentsFileName);
    Add('allowaccesstosystem', BoolToStrValue(AAgent.AllowAccessToSystem));
    Add('blocksensitivefiles', BoolToStrValue(AAgent.BlockSensitiveFiles));
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
    if AAgent.WebOptions.AllowedHosts.Count = 0 then
      Add('web.allowedhosts', '(any host)')
    else if AAgent.WebOptions.AllowedHosts.Count > 5 then
      Add('web.allowedhosts', IntToStr(AAgent.WebOptions.AllowedHosts.Count) + ' hosts, use "get web.allowedhosts" to list')
    else
      Add('web.allowedhosts', StringReplace(AAgent.WebOptions.AllowedHosts.CommaText, ',', ', ', [rfReplaceAll]));
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
    AError := 'unknown property: ' + AName + ', use "help" for list';
    Exit;
  end;
  // Manager-owned properties
  if (Canonical = 'baseurl') or (Canonical = 'keepalive') or (Canonical = 'autorefresh') or
    (Canonical = 'connectiontimeout') or (Canonical = 'manager.timeout') or (Canonical = 'pulltimeout') or
    (Canonical = 'modeltimeout') or (Canonical = 'numctx') or (Canonical = 'active') then
  begin
    if not Assigned(AAgent.OllamaManager) then
    begin
      AError := 'agent has no OllamaManager';
      Exit;
    end;
    if Canonical = 'baseurl' then
      AValue := AAgent.OllamaManager.BaseURL
    else if Canonical = 'keepalive' then
      AValue := IntToStr(AAgent.OllamaManager.KeepAlive)
    else if Canonical = 'autorefresh' then
      AValue := BoolToStrValue(AAgent.OllamaManager.AutoRefresh)
    else if Canonical = 'connectiontimeout' then
      AValue := IntToStr(AAgent.OllamaManager.ConnectionTimeout)
    else if Canonical = 'manager.timeout' then
      AValue := IntToStr(AAgent.OllamaManager.RequestTimeout)
    else if Canonical = 'pulltimeout' then
      AValue := IntToStr(AAgent.OllamaManager.PullTimeout)
    else if Canonical = 'modeltimeout' then
      AValue := IntToStr(AAgent.OllamaManager.ModelTimeout)
    else if Canonical = 'numctx' then
      AValue := IntToStr(AAgent.OllamaManager.NumCtx)
    else if Canonical = 'active' then
      AValue := BoolToStrValue(AAgent.OllamaManager.Active);
  end
  // Agent-owned properties
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
  else if Canonical = 'logtoolresult' then
    AValue := BoolToStrValue(AAgent.LogToolResult)
  else if Canonical = 'loadagentsmd' then
    AValue := BoolToStrValue(AAgent.LoadAgentsMd)
  else if Canonical = 'agentsfilename' then
    AValue := AAgent.AgentsFileName
  else if Canonical = 'allowaccesstosystem' then
    AValue := BoolToStrValue(AAgent.AllowAccessToSystem)
  else if Canonical = 'blocksensitivefiles' then
    AValue := BoolToStrValue(AAgent.BlockSensitiveFiles)
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
    AError := 'unknown property: ' + AName + ', use "help" for list';
    Exit;
  end;
  Value := Trim(AValue);
  // Strip surrounding quotes for string values
  if (Length(Value) >= 2) and (Value[1] = '"') and (Value[Length(Value)] = '"') then
    Value := Copy(Value, 2, Length(Value) - 2);

  // Manager-owned properties
  if (Canonical = 'baseurl') or (Canonical = 'keepalive') or (Canonical = 'autorefresh') or
    (Canonical = 'connectiontimeout') or (Canonical = 'manager.timeout') or (Canonical = 'pulltimeout') or
    (Canonical = 'modeltimeout') or (Canonical = 'numctx') or (Canonical = 'active') then
  begin
    if not Assigned(AAgent.OllamaManager) then
    begin
      AError := 'agent has no OllamaManager';
      Exit;
    end;
    if Canonical = 'baseurl' then
    begin
      if Trim(Value) = '' then
      begin
        AError := 'baseurl cannot be empty';
        Exit;
      end;
      AAgent.OllamaManager.BaseURL := Value;
    end
    else if Canonical = 'keepalive' then
    begin
      if not TryStrToInt(Value, IntVal) then
      begin
        AError := 'keepalive must be an integer';
        Exit;
      end;
      AAgent.OllamaManager.KeepAlive := IntVal;
    end
    else if Canonical = 'autorefresh' then
    begin
      if not ParseBoolValue(Value, BoolVal) then
      begin
        AError := 'autorefresh must be on/off, true/false, yes/no';
        Exit;
      end;
      AAgent.OllamaManager.AutoRefresh := BoolVal;
    end
    else if Canonical = 'connectiontimeout' then
    begin
      if not TryStrToInt(Value, IntVal) or (IntVal < 0) then
      begin
        AError := 'connectiontimeout must be a non-negative integer';
        Exit;
      end;
      AAgent.OllamaManager.ConnectionTimeout := IntVal;
    end
    else if Canonical = 'manager.timeout' then
    begin
      if not TryStrToInt(Value, IntVal) or (IntVal < 0) then
      begin
        AError := 'manager.timeout must be a non-negative integer';
        Exit;
      end;
      AAgent.OllamaManager.RequestTimeout := IntVal;
    end
    else if Canonical = 'pulltimeout' then
    begin
      if not TryStrToInt(Value, IntVal) or (IntVal < 0) then
      begin
        AError := 'pulltimeout must be a non-negative integer';
        Exit;
      end;
      AAgent.OllamaManager.PullTimeout := IntVal;
    end
    else if Canonical = 'modeltimeout' then
    begin
      if not TryStrToInt(Value, IntVal) or (IntVal < 0) then
      begin
        AError := 'modeltimeout must be a non-negative integer';
        Exit;
      end;
      AAgent.OllamaManager.ModelTimeout := IntVal;
    end
    else if Canonical = 'numctx' then
    begin
      if not TryStrToInt(Value, IntVal) or (IntVal < 0) then
      begin
        AError := 'numctx must be a non-negative integer';
        Exit;
      end;
      AAgent.OllamaManager.NumCtx := IntVal;
    end
    else if Canonical = 'active' then
    begin
      if not ParseBoolValue(Value, BoolVal) then
      begin
        AError := 'active must be on/off, true/false, yes/no';
        Exit;
      end;
      AAgent.OllamaManager.Active := BoolVal;
    end;
  end
  // Agent-owned properties
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
  else if Canonical = 'logtoolresult' then
  begin
    if not ParseBoolValue(Value, BoolVal) then
    begin
      AError := 'logtoolresult must be on/off, true/false, yes/no';
      Exit;
    end;
    AAgent.LogToolResult := BoolVal;
  end
  else if Canonical = 'loadagentsmd' then
  begin
    if not ParseBoolValue(Value, BoolVal) then
    begin
      AError := 'loadagentsmd must be on/off, true/false, yes/no';
      Exit;
    end;
    AAgent.LoadAgentsMd := BoolVal;
  end
  else if Canonical = 'agentsfilename' then
  begin
    if Value = '' then
    begin
      AError := 'agentsfilename cannot be empty';
      Exit;
    end;
    AAgent.AgentsFileName := Value;
  end
  else if Canonical = 'allowaccesstosystem' then
  begin
    if not ParseBoolValue(Value, BoolVal) then
    begin
      AError := 'allowaccesstosystem must be on/off, true/false, yes/no';
      Exit;
    end;
    AAgent.AllowAccessToSystem := BoolVal;
  end
  else if Canonical = 'blocksensitivefiles' then
  begin
    if not ParseBoolValue(Value, BoolVal) then
    begin
      AError := 'blocksensitivefiles must be on/off, true/false, yes/no';
      Exit;
    end;
    AAgent.BlockSensitiveFiles := BoolVal;
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

    // Fast path: manager already connected, use cached list without HTTP
    if AAgent.OllamaManager.IsConnected and not AAgent.OllamaManager.IsConnecting then
    begin
      Collector.Models.Assign(AAgent.OllamaManager.InstalledModels);
      Collector.Success := True;
      Collector.Done := True;
    end
    else
    begin
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
        while (not Collector.Done) and (GetTickCount64 - StartTime < QWord(Timeout)) do
          CheckSynchronize(50);
        if (not Collector.Done) and AAgent.OllamaManager.IsConnected then
        begin
          Collector.Models.Assign(AAgent.OllamaManager.InstalledModels);
          Collector.Success := True;
          Collector.Done := True;
        end;
      finally
        AAgent.OllamaManager.OnModelsRefreshed := OldModelsHandler;
        AAgent.OllamaManager.OnError := OldErrorHandler;
      end;
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
