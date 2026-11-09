import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { t } from '../i18n';
import { translateServer } from '../i18n/server';
import { isNative, PUBLIC_URL } from './native';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

/** null, solange die Supabase-Zugangsdaten fehlen (siehe README). */
export const supabase: SupabaseClient | null =
  url && key ? createClient(url, key, { auth: { persistSession: true, autoRefreshToken: true } }) : null;

export function db(): SupabaseClient {
  if (!supabase) throw new Error('Supabase ist nicht konfiguriert.');
  return supabase;
}

/** Fehlermeldungen von Supabase verständlich und in der eingestellten Sprache. */
export function errorText(error: unknown): string {
  const e = error as { message?: string; code?: string } | null;
  const msg = e?.message ?? String(error);
  if (e?.code === '23505' && msg.includes('username')) return t('Dieser Benutzername ist schon vergeben.');
  if (msg.includes('Invalid login credentials')) return t('E-Mail oder Passwort ist falsch.');
  if (msg.includes('Email not confirmed')) return t('Bitte bestätige zuerst deine E-Mail-Adresse (Link im Postfach).');
  if (msg.includes('User already registered')) return t('Mit dieser E-Mail gibt es schon ein Konto.');
  if (msg.includes('rate limit')) return t('Zu viele Versuche. Bitte warte kurz und versuche es nochmals.');
  if (msg.includes('Password should be')) return t('Das Passwort ist zu schwach.');
  return translateServer(msg);
}

/** Absolute Adresse innerhalb der App, auch wenn sie unter einem Unterpfad läuft. */
export function appUrl(path = '/'): string {
  // In der Handy-App zeigen Links auf die öffentliche Web-App (sonst wäre es "localhost").
  if (isNative) return `${PUBLIC_URL}${path}`;
  return `${window.location.origin}${import.meta.env.BASE_URL.replace(/\/$/, '')}${path}`;
}
