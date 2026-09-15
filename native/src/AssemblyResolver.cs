using System;
using System.IO;
using System.Reflection;

namespace SpinCam
{
    /// <summary>
    /// Resolves SpinnakerNET / SpinVideoNET for the engine when MATLAB loaded them from the
    /// Spinnaker install folder. Must not reference any Spinnaker type, because it runs
    /// before those assemblies are bound.
    /// </summary>
    public static class AssemblyResolver
    {
        private static readonly object Sync = new object();
        private static string _directory;
        private static bool _registered;

        public static void Register(string directory)
        {
            lock (Sync)
            {
                _directory = directory;
                if (!_registered)
                {
                    AppDomain.CurrentDomain.AssemblyResolve += OnResolve;
                    _registered = true;
                }
            }
        }

        private static Assembly OnResolve(object sender, ResolveEventArgs args)
        {
            string name = new AssemblyName(args.Name).Name;
            foreach (Assembly loaded in AppDomain.CurrentDomain.GetAssemblies())
            {
                if (string.Equals(loaded.GetName().Name, name, StringComparison.OrdinalIgnoreCase))
                {
                    return loaded;
                }
            }
            string dir;
            lock (Sync)
            {
                dir = _directory;
            }
            if (!string.IsNullOrEmpty(dir))
            {
                string candidate = Path.Combine(dir, name + ".dll");
                if (File.Exists(candidate))
                {
                    return Assembly.LoadFrom(candidate);
                }
            }
            return null;
        }
    }
}
