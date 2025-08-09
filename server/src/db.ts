import pg from 'pg'; const { Pool } = pg;
export const pool = new Pool({ connectionString: process.env.DATABASE_URL });
export async function query<T=any>(text: string, params?: any[]): Promise<{ rows: T[] }> { return pool.query(text, params); }
