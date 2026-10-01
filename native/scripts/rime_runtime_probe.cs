// Kirakara test harness: MIT. ABI layouts follow librime e053fb29, whose
// original rime_api.h is Copyright RIME Developers, distributed under BSD.
// See third_party/licenses/librime-BSD-3-Clause.txt. No upstream header removed.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace Kirakara.RimeRuntimeProbe {
  public sealed class Result {
    public string[] Schemas { get; set; }
    public int CandidateChecks { get; set; }
    public bool SimplificationVerified { get; set; }
    public bool NormalFinalization { get; set; }
  }
  public static class Probe {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr LoadLibraryExW(string name, IntPtr file, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi, ExactSpelling=true)]
    static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);

    [StructLayout(LayoutKind.Sequential)] struct Traits {
      public int Size;
      public IntPtr Shared, User, DistributionName, DistributionCode, DistributionVersion, App;
      public IntPtr Modules;
      public int MinLog;
      public IntPtr Log, Prebuilt, Staging;
    }
    [StructLayout(LayoutKind.Sequential)] struct Composition {
      public int Length, Cursor, SelectionStart, SelectionEnd;
      public IntPtr Preedit;
    }
    [StructLayout(LayoutKind.Sequential)] struct Menu {
      public int PageSize, PageNumber, IsLastPage, Highlighted, Count;
      public IntPtr Candidates, SelectKeys;
    }
    [StructLayout(LayoutKind.Sequential)] struct Context {
      public int Size;
      public Composition Composition;
      public Menu Menu;
      public IntPtr Preview, Labels;
    }
    [StructLayout(LayoutKind.Sequential)] struct Candidate {
      public IntPtr Text, Comment, Reserved;
    }
    [StructLayout(LayoutKind.Sequential)] struct Iterator {
      public IntPtr State;
      public int Index;
      public Candidate Candidate;
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void Setup(ref Traits traits);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void Initialize(IntPtr traits);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void VoidCall();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Maintenance(int full);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate UIntPtr Create();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Destroy(UIntPtr session);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SessionText(UIntPtr session, IntPtr text);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void SetOption(UIntPtr session, IntPtr name, int value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int GetContext(UIntPtr session, ref Context context);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FreeContext(ref Context context);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int BeginCandidates(UIntPtr session, ref Iterator iterator);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NextCandidate(ref Iterator iterator);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void EndCandidates(ref Iterator iterator);

    static T Export<T>(IntPtr module, string name) where T:Delegate {
      var address=GetProcAddress(module,name);
      if(address==IntPtr.Zero) throw new InvalidOperationException("缺少测试需要的 Rime 导出："+name);
      return Marshal.GetDelegateForFunctionPointer<T>(address);
    }
    public static Result Run(string dll, string shared, string state) {
      if(IntPtr.Size!=8) throw new InvalidOperationException("探测进程必须为 x64。");
      var module=LoadLibraryExW(dll,IntPtr.Zero,0x900);
      if(module==IntPtr.Zero) throw new InvalidOperationException("librime 加载失败，错误码："+Marshal.GetLastWin32Error());
      var allocated=new List<IntPtr>();
      Func<string,IntPtr> utf8=value=>{var p=Marshal.StringToCoTaskMemUTF8(value);allocated.Add(p);return p;};
      VoidCall finalize=null;
      bool initialized=false;
      var result=new Result();
      try {
        var setup=Export<Setup>(module,"RimeSetup");
        var initialize=Export<Initialize>(module,"RimeInitialize");
        finalize=Export<VoidCall>(module,"RimeFinalize");
        var maintenance=Export<Maintenance>(module,"RimeStartMaintenance");
        var join=Export<VoidCall>(module,"RimeJoinMaintenanceThread");
        var create=Export<Create>(module,"RimeCreateSession");
        var destroy=Export<Destroy>(module,"RimeDestroySession");
        var select=Export<SessionText>(module,"RimeSelectSchema");
        var setInput=Export<SessionText>(module,"RimeSetInput");
        var setOption=Export<SetOption>(module,"RimeSetOption");
        var getContext=Export<GetContext>(module,"RimeGetContext");
        var freeContext=Export<FreeContext>(module,"RimeFreeContext");
        var beginCandidates=Export<BeginCandidates>(module,"RimeCandidateListBegin");
        var nextCandidate=Export<NextCandidate>(module,"RimeCandidateListNext");
        var endCandidates=Export<EndCandidates>(module,"RimeCandidateListEnd");
        var user=Path.Combine(state,"user");
        var build=Path.Combine(user,"build");
        var prebuilt=Path.Combine(state,"prebuilt");
        Directory.CreateDirectory(build); Directory.CreateDirectory(prebuilt);
        var traits=new Traits {Size=Marshal.SizeOf<Traits>()-sizeof(int),Shared=utf8(shared),User=utf8(user),
          DistributionName=utf8("Kirakara isolated test"),DistributionCode=utf8("kirakara-probe"),
          DistributionVersion=utf8("1"),App=utf8("rime.kirakara-probe"),MinLog=3,
          Log=utf8(state),Prebuilt=utf8(prebuilt),Staging=utf8(build)};
        setup(ref traits);
        initialize(IntPtr.Zero); initialized=true;
        if(maintenance(1)!=0) join();
        var schemas=new[]{"luna_pinyin","luna_pinyin_simp","luna_pinyin_fluency","bopomofo","bopomofo_tw","stroke","terra_pinyin"};
        foreach(var schema in schemas) {
          var session=create();
          if(session==UIntPtr.Zero) throw new InvalidOperationException("测试会话创建失败。");
          try {
            if(select(session,utf8(schema))==0) throw new InvalidOperationException("测试方案部署/选择失败："+schema);
            if(schema!="luna_pinyin" && schema!="luna_pinyin_simp") continue;
            setOption(session,utf8("ascii_mode"),0);
            if(schema=="luna_pinyin_simp") setOption(session,utf8("zh_simp"),1);
            // Fixed synthetic fixtures; never read actual keystrokes, clipboard
            // or AppData, and never include input/candidate text in reports.
            var input=schema=="luna_pinyin_simp"?"han":"shijie";
            var expected=schema=="luna_pinyin_simp"?"汉":"世界";
            if(setInput(session,utf8(input))==0) throw new InvalidOperationException("测试输入未被接受。");
            var context=new Context {Size=Marshal.SizeOf<Context>()-sizeof(int)};
            if(getContext(session,ref context)==0) throw new InvalidOperationException("测试候选上下文读取失败。");
            try {
              if(context.Menu.Count<=0 || context.Menu.Count>1000 || context.Menu.Candidates==IntPtr.Zero)
                throw new InvalidOperationException("测试候选列表为空或越界。");
            } finally {
              if(freeContext(ref context)==0) throw new InvalidOperationException("候选上下文释放失败。");
            }
            // A page has only five entries. Validate the finite candidate list
            // rather than incorrectly assuming every test word ranks on page 1.
            var iterator=new Iterator();
            if(beginCandidates(session,ref iterator)==0) throw new InvalidOperationException("候选迭代器初始化失败。");
            bool found=false;
            try {
              for(int i=0;i<128 && nextCandidate(ref iterator)!=0;i++) {
                if(Marshal.PtrToStringUTF8(iterator.Candidate.Text)==expected) {found=true;break;}
              }
            } finally {endCandidates(ref iterator);}
            if(!found) throw new InvalidOperationException("固定候选内容或简繁转换不符合预期："+schema);
            result.CandidateChecks++;
            if(schema=="luna_pinyin_simp") result.SimplificationVerified=true;
          } finally {
            if(destroy(session)==0) throw new InvalidOperationException("测试会话释放失败。");
          }
        }
        result.Schemas=schemas;
        finalize(); initialized=false; result.NormalFinalization=true;
        return result;
      } finally {
        if(initialized && finalize!=null) finalize();
        for(int i=allocated.Count-1;i>=0;i--) Marshal.FreeCoTaskMem(allocated[i]);
        FreeLibrary(module);
      }
    }
  }
}
