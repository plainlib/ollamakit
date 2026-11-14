//-----------------------------------------------------------------------------------
//  OllamaKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit OllamaKitRegister;

{$mode objfpc}{$H+}

interface

uses
  Controls, Classes, LResources, PropEdits, GraphPropEdits, OllamaManager, TermManager;

procedure Register;

implementation

type
  // Multiline editor for the Welcome banner
  TTermWelcomePropertyEditor = class(TStringMultilinePropertyEditor)
  public
    function GetAttributes: TPropertyAttributes; override;
  end;

function TTermWelcomePropertyEditor.GetAttributes: TPropertyAttributes;
begin
  Result := inherited GetAttributes + [paDialog];
end;

procedure Register;
begin
  RegisterComponents('Common Controls', [TOllamaManager, TTermManager]);

  // Welcome is declared as TCaption, so match its RTTI type
  RegisterPropertyEditor(TypeInfo(TCaption), TTermManager, 'Welcome',
    TTermWelcomePropertyEditor);
end;

initialization

  {$I ollamakit.lrs}

end.
