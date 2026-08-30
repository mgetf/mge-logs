# Third-Party Notices

This project vendors the following third-party SourcePawn includes under
`scripting/include/` so the plugin can be compiled standalone.
They are not original work of this project and retain their own licenses.

## mge.inc

Public API include from [MGEMod](https://github.com/mgetf/MGEMod) (a fork of
[sappho's MGEMod](https://github.com/sapphonie/MGEMod)), providing the forwards
and natives this plugin's lifecycle layer depends on (`MGE_On1v1MatchStart`,
`MGE_OnPlayerELOChange`, etc.).

## ripext.inc / ripext/http.inc / ripext/json.inc

Includes for [sm-ripext](https://github.com/ErasedDeath/sm-ripext) ("REST in
Pawn"), used for the optional HTTP upload of completed match logs to the
mge.tf backend (`mge_logs_upload` ConVar).
