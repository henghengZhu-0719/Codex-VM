import React from 'react';
import { AlertTriangle, CheckCircle2, Info, X } from 'lucide-react';
import { bridge } from '../bridge.js';

export default function ToastStack({ toasts = [], onNavigateVM }) {
  if (!toasts.length) return null;
  return (
    <div className="toast-stack" role="status" aria-live="polite">
      {toasts.map(t => {
        const icon =
          t.level === 'error' ? <AlertTriangle size={15} color="var(--bad)" /> :
          t.level === 'ok' ? <CheckCircle2 size={15} color="var(--ok)" /> :
          <Info size={15} color="var(--blue)" />;
        return (
          <div key={t.id} className={'toast-item ' + (t.level || 'info')}>
            <div className="toast-icon">{icon}</div>
            <div
              className="toast-body"
              onClick={() => {
                if (t.vm && onNavigateVM) onNavigateVM(t.vm);
                bridge('toastDismiss', { id: t.id });
              }}
              style={{ cursor: t.vm ? 'pointer' : 'default' }}
            >
              <strong>{t.title}</strong>
              {t.message && <span>{t.message}</span>}
            </div>
            <button
              type="button"
              className="toast-close"
              aria-label="关闭通知"
              onClick={() => bridge('toastDismiss', { id: t.id })}
            >
              <X size={13} />
            </button>
          </div>
        );
      })}
    </div>
  );
}
