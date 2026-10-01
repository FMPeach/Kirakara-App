// Kirakara 自有包验证代码，采用仓库根目录 MIT License。
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace Kirakara.Artifacts {
  public static class Security {
    public static string RelativePath(string value, bool directory = false) {
      if (String.IsNullOrEmpty(value) || value.Length > 240 ||
          value.StartsWith("/") || value.Contains("\\") ||
          Regex.IsMatch(value, "[\\x00-\\x1f:<>\"|?*]"))
        throw new InvalidDataException("Unsafe package path: " + value);
      string path = directory && value.EndsWith("/") ? value.Substring(0, value.Length - 1) : value;
      foreach (string segment in path.Split('/')) {
        if (segment.Length == 0 || segment == "." || segment == ".." ||
            segment.EndsWith(".") || segment.EndsWith(" ") ||
            Regex.IsMatch(segment, "^(CON|PRN|AUX|NUL|COM[0-9¹²³]|LPT[0-9¹²³])(?:\\.|$)", RegexOptions.IgnoreCase))
          throw new InvalidDataException("Unsafe package path: " + value);
      }
      return path;
    }

    public static string Child(string root, string relative) {
      string path = Path.GetFullPath(Path.Combine(root, RelativePath(relative).Replace('/', Path.DirectorySeparatorChar)));
      string prefix = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
      if (!path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        throw new InvalidDataException("Package path escapes its root");
      return path;
    }

    public static void NoReparse(string path) {
      string current = Path.GetFullPath(path);
      while (!String.IsNullOrEmpty(current)) {
        if ((Directory.Exists(current) || File.Exists(current)) &&
            (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
          throw new InvalidDataException("Reparse point is not allowed in artifact storage: " + current);
        current = Path.GetDirectoryName(current);
      }
    }

    // Validate the entire central directory before creating any entry.
    // Destination must be a new private directory under the calling repository.
    public static void ExtractZip(string archive, string destination, long maxBytes, int maxEntries) {
      NoReparse(destination);
      if (Directory.Exists(destination) || File.Exists(destination))
        throw new InvalidDataException("Extraction destination already exists");
      using (var zip = ZipFile.OpenRead(archive)) {
        if (zip.Entries.Count == 0 || zip.Entries.Count > maxEntries)
          throw new InvalidDataException("Unexpected ZIP entry count");
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var files = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var spelling = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        long total = 0;
        foreach (var entry in zip.Entries) {
          bool dir = entry.FullName.EndsWith("/");
          string name = RelativePath(entry.FullName, dir);
          uint attributes = unchecked((uint)entry.ExternalAttributes);
          uint unixType = (attributes >> 16) & 0xf000;
          if ((attributes & 0x400) != 0 ||
              (unixType != 0 && unixType != 0x8000 && unixType != 0x4000) ||
              (unixType == 0x4000 && !dir) || (unixType == 0x8000 && dir))
            throw new InvalidDataException("Unsupported ZIP entry type: " + name);
          if (!paths.Add(name)) throw new InvalidDataException("Duplicate or case-colliding ZIP path: " + name);
          string prefix = "";
          foreach (string segment in name.Split('/')) {
            prefix = prefix.Length == 0 ? segment : prefix + "/" + segment;
            string previous;
            if (spelling.TryGetValue(prefix, out previous) && !String.Equals(prefix, previous, StringComparison.Ordinal))
              throw new InvalidDataException("Case-colliding ZIP directory spelling: " + prefix);
            spelling[prefix] = prefix;
          }
          if (entry.Length < 0 || entry.Length > maxBytes ||
              entry.CompressedLength < 0 || (dir && entry.Length != 0))
            throw new InvalidDataException("Invalid ZIP entry size");
          total = checked(total + entry.Length);
          if (total > maxBytes) throw new InvalidDataException("ZIP exceeds extraction size limit");
          if (!dir) files.Add(name);
          Child(destination, name);
        }
        foreach (string name in paths) {
          int slash = name.LastIndexOf('/');
          while (slash >= 0) {
            string parent = name.Substring(0, slash);
            if (files.Contains(parent)) throw new InvalidDataException("ZIP file/directory conflict: " + name);
            slash = parent.LastIndexOf('/');
          }
        }
        Directory.CreateDirectory(destination);
        foreach (var entry in zip.Entries) {
          bool dir = entry.FullName.EndsWith("/");
          string path = Child(destination, RelativePath(entry.FullName, dir));
          if (dir) { Directory.CreateDirectory(path); continue; }
          Directory.CreateDirectory(Path.GetDirectoryName(path));
          NoReparse(Path.GetDirectoryName(path));
          using (var input = entry.Open())
          using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
            byte[] buffer = new byte[65536];
            long copied = 0;
            int count;
            while ((count = input.Read(buffer, 0, buffer.Length)) > 0) {
              copied = checked(copied + count);
              if (copied > entry.Length) throw new InvalidDataException("ZIP content exceeds declared size");
              output.Write(buffer, 0, count);
            }
            if (copied != entry.Length) throw new InvalidDataException("Truncated ZIP entry");
          }
        }
      }
    }
  }

  public sealed class PeInfo {
    public ushort Machine { get; internal set; }
    public bool IsDll { get; internal set; }
    public string[] Exports { get; internal set; }
  }

  // Standalone PE reader: ordinary collaborators do not need llvm-readobj,
  // an Engine source checkout, or a locally installed linker to verify a DLL.
  public static class PeReader {
    private sealed class Section { public uint Rva, RawSize, RawOffset; }
    private static long Map(uint rva, uint length, Section[] sections, long fileLength) {
      foreach (var s in sections) {
        if ((ulong)rva >= s.Rva && (ulong)rva + length <= (ulong)s.Rva + s.RawSize) {
          long result = (long)s.RawOffset + rva - s.Rva;
          if (result >= 0 && result + length <= fileLength) return result;
        }
      }
      throw new InvalidDataException("Invalid PE RVA");
    }
    private static void Position(BinaryReader reader, long offset, long bytes) {
      if (offset < 0 || bytes < 0 || offset + bytes > reader.BaseStream.Length)
        throw new InvalidDataException("Truncated PE file");
      reader.BaseStream.Position = offset;
    }
    public static PeInfo Read(string path) {
      using (var stream = File.OpenRead(path))
      using (var reader = new BinaryReader(stream)) {
        Position(reader, 0, 64);
        if (reader.ReadUInt16() != 0x5a4d) throw new InvalidDataException("Not a PE file");
        Position(reader, 0x3c, 4);
        long pe = reader.ReadUInt32();
        Position(reader, pe, 24);
        if (reader.ReadUInt32() != 0x00004550) throw new InvalidDataException("Invalid PE signature");
        ushort machine = reader.ReadUInt16(), sectionCount = reader.ReadUInt16();
        Position(reader, pe + 20, 4);
        ushort optionalSize = reader.ReadUInt16(), characteristics = reader.ReadUInt16();
        if (sectionCount == 0 || sectionCount > 96 || optionalSize < 112)
          throw new InvalidDataException("Invalid PE header");
        long optional = pe + 24;
        Position(reader, optional, optionalSize);
        if (reader.ReadUInt16() != 0x20b || machine != 0x8664)
          throw new InvalidDataException("Expected a Windows x64 PE image");
        Position(reader, optional + 108, 4);
        uint directoryCount = reader.ReadUInt32();
        uint exportRva = 0, exportSize = 0;
        if (directoryCount > 0) {
          if (optionalSize < 120) throw new InvalidDataException("Invalid PE data directory");
          Position(reader, optional + 112, 8);
          exportRva = reader.ReadUInt32(); exportSize = reader.ReadUInt32();
        }
        var sections = new Section[sectionCount];
        long sectionTable = optional + optionalSize;
        for (int i = 0; i < sectionCount; i++) {
          Position(reader, sectionTable + i * 40 + 12, 12);
          sections[i] = new Section { Rva = reader.ReadUInt32(), RawSize = reader.ReadUInt32(), RawOffset = reader.ReadUInt32() };
        }
        var names = new List<string>();
        if (exportRva != 0) {
          long exports = Map(exportRva, 40, sections, stream.Length);
          Position(reader, exports + 20, 20);
          uint functionCount = reader.ReadUInt32(), nameCount = reader.ReadUInt32();
          uint functionRva = reader.ReadUInt32(), nameRva = reader.ReadUInt32(), ordinalRva = reader.ReadUInt32();
          if (functionCount > 100000 || nameCount > functionCount)
            throw new InvalidDataException("Invalid PE export count");
          long functions = Map(functionRva, checked(functionCount * 4), sections, stream.Length);
          long nameTable = Map(nameRva, checked(nameCount * 4), sections, stream.Length);
          long ordinals = Map(ordinalRva, checked(nameCount * 2), sections, stream.Length);
          for (uint i = 0; i < nameCount; i++) {
            Position(reader, nameTable + i * 4, 4);
            uint textRva = reader.ReadUInt32();
            Position(reader, ordinals + i * 2, 2);
            uint ordinal = reader.ReadUInt16();
            if (ordinal >= functionCount) throw new InvalidDataException("Invalid export ordinal");
            Position(reader, functions + ordinal * 4, 4);
            uint address = reader.ReadUInt32();
            var text = new StringBuilder();
            for (uint j = 0; ; j++) {
              if (j >= 1024) throw new InvalidDataException("Export name is too long");
              Position(reader, Map(checked(textRva + j), 1, sections, stream.Length), 1);
              byte c = reader.ReadByte();
              if (c == 0) break;
              if (c < 32 || c > 126) throw new InvalidDataException("Non-ASCII export name");
              text.Append((char)c);
            }
            // Forwarders and null entries cannot satisfy the native ABI gate.
            if (address != 0 && !((ulong)address >= exportRva && (ulong)address < (ulong)exportRva + exportSize))
              names.Add(text.ToString());
          }
        }
        return new PeInfo { Machine = machine, IsDll = (characteristics & 0x2000) != 0, Exports = names.ToArray() };
      }
    }
  }
}
