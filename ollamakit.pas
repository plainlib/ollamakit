{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit ollamakit;

{$warn 5023 off : no warning about unused units}
interface

uses
  OllamaManager, TermManager, OllamaKitRegister, LazarusPackageIntf;

implementation

procedure Register;
begin
  RegisterUnit('OllamaKitRegister', @OllamaKitRegister.Register);
end;

initialization
  RegisterPackage('ollamakit', @Register);
end.
