package ch.huntmode.app;

import android.view.HapticFeedbackConstants;
import android.view.View;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/**
 * Kurzes Antippen-Feedback (Knöpfe) über die System-Funktion von Android. Sie beachtet die Einstellung
 * "Haptisches Feedback / Vibration bei Berührung": ist sie aus, vibriert auch die App nicht.
 */
@CapacitorPlugin(name = "SystemHaptics")
public class SystemHapticsPlugin extends Plugin {
    @PluginMethod
    public void tap(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            View v = getBridge().getWebView();
            if (v != null) v.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY);
            call.resolve();
        });
    }
}
