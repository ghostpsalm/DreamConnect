package dreamconnect.boot;

/**
 * One session as the root-owned registry describes it: which account owns it
 * ({@code uid}/{@code user}), the X display it serves, the shm frame buffer to
 * read, the control socket to send input to, and the name to show in
 * ScreenConnect's session picker.
 *
 * Since 2026-08-16 these come from {@code /run/dreamconnect/sessions/<uid>},
 * written by root (docs/specs/multi-session-picker.md, Solution 1) — never from
 * scanning a directory any account can write to. {@code user} is what the
 * connected peer must prove itself to be over SO_PEERCRED before a byte is
 * sent; {@code uid} is what the shm file must be owned by.
 *
 * {@code display} is verbatim as registered (":0" or ":0.0"); normalising it is
 * {@link Bridge#normalizeDisplay}'s job, not this type's.
 *
 * {@code uid} is -1 and {@code user} null for the one endpoint that does not
 * come from the registry: the static shm=/socket= agent args, which are the
 * operator's own configuration and answer to no registry entry.
 *
 * Carries data and holds no rules: which endpoint a session attaches to is
 * {@link Bridge#resolveEndpoint}'s decision, and whether one may be trusted is
 * {@link Bridge#trustedFile} / {@link Bridge#usableShm} / the peer credential.
 */
record SessionEndpoint(long uid, String user, String display,
                       String shm, String socket, String label) {
}
