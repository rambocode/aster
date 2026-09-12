#ifndef ASTER_BRIDGE_SIGNALS_H
#define ASTER_BRIDGE_SIGNALS_H
// Install process-local wakeup handlers, returning a nonblocking read FD.
// Only one runtime component (bridge or service) may own this guard.
// SIGCHLD wakes the owner to reap only its own children; it is not a stop.
// stop restores all prior handlers.
int session_bridge_signals_start(void);
int session_bridge_signals_take(void);
void session_bridge_signals_stop(void);
#endif
