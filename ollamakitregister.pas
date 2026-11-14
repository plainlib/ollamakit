//-----------------------------------------------------------------------------------
//  OllamaKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit OllamaKitRegister;

{$mode objfpc}{$H+}

interface

uses
  Controls, Classes, LResources, PropEdits, GraphPropEdits,
  OllamaManager, OllamaAgent, TermManager;

procedure Register;

implementation

type
  // Multiline editor for the Welcome banner
  TTermWelcomePropertyEditor = class(TStringMultilinePropertyEditor)
  public
    function GetAttributes: TPropertyAttributes; override;
  end;

  // Multiline editor shared by agent and tool multiline properties
  TAgentMultilinePropertyEditor = class(TStringMultilinePropertyEditor)
  public
    function GetAttributes: TPropertyAttributes; override;
  end;

function TTermWelcomePropertyEditor.GetAttributes: TPropertyAttributes;
begin
  Result := inherited GetAttributes + [paDialog];
end;

function TAgentMultilinePropertyEditor.GetAttributes: TPropertyAttributes;
begin
  Result := inherited GetAttributes + [paDialog];
end;

procedure Register;
begin
  RegisterComponents('Common Controls', [TOllamaManager, TTermManager, TOllamaAgent]);

  // Welcome is declared as TCaption, so match its RTTI type
  RegisterPropertyEditor(TypeInfo(TCaption), TTermManager, 'Welcome',
    TTermWelcomePropertyEditor);

  // Agent multiline properties use the shared multiline editor
  RegisterPropertyEditor(TypeInfo(TCaption), TCustomOllamaAgent, 'SystemPrompt',
    TAgentMultilinePropertyEditor);
  RegisterPropertyEditor(TypeInfo(TCaption), TAgentTool, 'Description',
    TAgentMultilinePropertyEditor);
  RegisterPropertyEditor(TypeInfo(TCaption), TAgentTool, 'ParametersJson',
    TAgentMultilinePropertyEditor);
end;

initialization

  {$I ollamakit.lrs}

end.
