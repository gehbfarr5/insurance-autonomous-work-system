import android.content.ComponentName;
import android.content.pm.PackageManager;
import android.os.IBinder;
import android.os.Process;
import java.lang.reflect.Method;

/** Root-only, one fixed component; restore state without killing AutoX engines.
 * Android 15 IPackageManager signature is deliberately exact; no version fallback.
 */
public final class AuthComponentState {
    private static final ComponentName TARGET = new ComponentName(
        "org.autojs.autoxjs.v7", "org.autojs.autojs.external.open.RunIntentActivity");
    public static void main(String[] args) throws Exception {
        if (Process.myUid() != 0) throw new SecurityException("ROOT_REQUIRED");
        if (!(args.length == 1 && args[0].equals("get")) &&
            !(args.length == 2 && args[0].equals("set") && args[1].matches("[012]")))
            throw new IllegalArgumentException("EXPECTED_GET_OR_SET_0_1_2");
        Class<?> manager = Class.forName("android.os.ServiceManager");
        IBinder binder = (IBinder) manager.getMethod("getService", String.class).invoke(null, "package");
        Object service = Class.forName("android.content.pm.IPackageManager$Stub")
            .getMethod("asInterface", IBinder.class).invoke(null, binder);
        Class<?> api = Class.forName("android.content.pm.IPackageManager");
        Method get = api.getMethod("getComponentEnabledSetting", ComponentName.class, int.class);
        if (args[0].equals("set")) {
            int state = Integer.parseInt(args[1]);
            api.getMethod("setComponentEnabledSetting", ComponentName.class, int.class,
                int.class, int.class, String.class).invoke(service, TARGET, state,
                PackageManager.DONT_KILL_APP, 0, "shell");
            if (((Integer) get.invoke(service, TARGET, 0)).intValue() != state)
                throw new IllegalStateException("COMPONENT_STATE_READBACK_MISMATCH");
        }
        System.out.println(get.invoke(service, TARGET, 0));
    }
}
