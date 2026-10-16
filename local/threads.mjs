// Personal chat storage on the Mac. No model credentials are stored in chat rows.
import { DatabaseSync } from 'node:sqlite';
import { chmod } from 'node:fs/promises';
import { resolve } from 'node:path';

export async function openThreads(directory) {
  const path = resolve(directory, 'threads.sqlite');
  const db = new DatabaseSync(path);
  await chmod(path, 0o600);
  db.exec(`PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS threads (
      client TEXT NOT NULL, id TEXT NOT NULL, revision INTEGER NOT NULL,
      updated TEXT NOT NULL, document TEXT NOT NULL, PRIMARY KEY(client, id)
    );`);
  const list = db.prepare('SELECT document FROM threads WHERE client = ? ORDER BY updated DESC');
  const get = db.prepare('SELECT document FROM threads WHERE client = ? AND id = ?');
  const put = db.prepare(`INSERT INTO threads(client,id,revision,updated,document) VALUES(?,?,?,?,?)
    ON CONFLICT(client,id) DO UPDATE SET revision=excluded.revision, updated=excluded.updated, document=excluded.document
    WHERE excluded.revision > threads.revision`);
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  return async function threads(req, res, url, readBody, json) {
    const client = req.headers['x-agentone-client'];
    if (!uuid.test(client || '')) return json(res, { error: 'A valid chat client ID is required' }, 400);
    if (req.method === 'GET' && url.pathname === '/api/threads') {
      return json(res, { threads: list.all(client).map(row => JSON.parse(row.document)) });
    }
    const id = url.pathname.slice('/api/threads/'.length);
    if (!uuid.test(id)) return json(res, { error: 'Invalid thread ID' }, 400);
    if (req.method === 'PUT') {
      const thread = await readBody(req);
      if (thread.id !== id || typeof thread.title !== 'string' || !Array.isArray(thread.messages)
        || !Number.isSafeInteger(thread.revision) || thread.revision < 1
        || !Number.isFinite(Date.parse(thread.updatedAt))) return json(res, { error: 'Invalid chat thread' }, 400);
      const document = JSON.stringify(thread);
      if (Buffer.byteLength(document) > 2 * 1024 * 1024) return json(res, { error: 'Thread exceeds 2 MB' }, 413);
      put.run(client, id, thread.revision, thread.updatedAt, document);
      return json(res, { thread: JSON.parse(get.get(client, id).document) });
    }
    if (req.method === 'GET') {
      const row = get.get(client, id);
      return row ? json(res, { thread: JSON.parse(row.document) }) : json(res, { error: 'Thread not found' }, 404);
    }
    return json(res, { error: 'Method not allowed' }, 405);
  };
}
