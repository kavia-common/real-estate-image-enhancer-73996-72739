Backend integration with RLS

To enforce user-level data isolation, the backend must set a session parameter per request/transaction with the authenticated user's UUID:
- SQL: SELECT set_config('app.current_user_id', '<user-uuid>', true);

Guidelines:
- Always open a transaction (BEGIN) when handling a request.
- Immediately set app.current_user_id to the authenticated user id.
- Perform queries using the least-privileged role (app_rw).
- On admin actions, authenticate the admin in the backend and either:
  - continue with app_rw but use dedicated admin APIs that rely on backend authorization and RLS exceptions for current_user = 'app_admin', or
  - switch connection to app_admin only for controlled maintenance tasks (not for serving user requests).

Example (psycopg3):
with conn:
    with conn.cursor() as cur:
        cur.execute("SELECT set_config('app.current_user_id', %s, true)", (user_id,))
        # Now any SELECT/UPDATE/INSERT on app.* tables is restricted to the user.
