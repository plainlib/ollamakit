//-----------------------------------------------------------------------------------
//  OllamaKit Package © 2026 by Alexander Tverskoy
//  Licensed under the MIT License
//  You may obtain a copy of the License at https://opensource.org/licenses/MIT
//-----------------------------------------------------------------------------------

unit OllamaKitRegister;

{$mode objfpc}{$H+}

interface

uses
  Controls, Classes, LResources, OllamaManager;

procedure Register;

implementation

procedure Register;
begin
  RegisterComponents('Common Controls', [TOllamaManager]);
end;

initialization

  {$I ollamakit.lrs}

end.
