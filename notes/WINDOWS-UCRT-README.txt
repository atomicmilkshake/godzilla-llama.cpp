STOP — do not rediscover library paths.

Canonical docs (same content, multiple locations on purpose):

  docs\WINDOWS-BUILD-TOOLCHAIN.md
  docs\LOCAL-SETUP.example.md
  GODZILLA_KING.md  (Windows rebuild section)
  scripts\env-godzilla-msvc.cmd
  rebuild_king.cmd
  J:\LLM\engines\BUILD-WINDOWS.md
  X:\My Drive\VandelayNexus\docs\GODZILLA-BUILD.md
  C:\Users\owenm\.grok\Agents.md  (agent global reminder)

Root cause: VS18 vcvars omits UCRT → LNK1104 ucrtd.lib
Fix: call scripts\env-godzilla-msvc.cmd  (prepends S:\WADK102 UCRT)

One shot: rebuild_king.cmd
