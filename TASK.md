# Tasks

## Combined user acceptance after design

- Exercise the local app transitions and Codex/Claude switching, quota identity and saved conversation resume jointly with the user.
- Continue technical stages without blocking on user acceptance. After design, jointly exercise Stage 1 switching/recovery and Stage 2 account import, second login, removal and reimport.
- After design, also verify agent state, process/log binding, message timestamps and work-duration provenance through the final interface.
- After design, validate the unified local statistics, selected-provider coverage, source warnings, model names and separate account reports against representative retained history.
- Track automated implementation separately from user-confirmed behavior; do not publish a release.


## Account statistics

- Keep mixed and per-provider statistics readable across several accounts.
- Shared accounts, stable badges, multiple provider connections, native sign-in,
  and quota selection are implemented. Statistics still uses the established
  default Codex analytics scope; multi-account analytics remains separate work.
