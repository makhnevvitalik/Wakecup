import Foundation
import CryptoKit
import Darwin

// Only bytes authenticated by the running app's compiled-in pin may be elevated.
// The root shell keeps the protected copy alive until its actual child exits.
enum PrivilegedExecution {
    // Preflight must be bounded too; a bundle path is writable and may be
    // replaced before the administrator prompt is even prepared.
    static func sourceDigest(at source: URL) throws -> String {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw damagedSource() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= HelperConstants.maximumExecutableBytes else { throw damagedSource() }
        var digest = SHA256()
        var total = 0
        while let data = try file.read(upToCount: min(65_536, HelperConstants.maximumExecutableBytes - total + 1)), !data.isEmpty {
            guard data.count <= HelperConstants.maximumExecutableBytes - total else { throw damagedSource() }
            total += data.count
            digest.update(data: data)
        }
        guard total > 0 else { throw damagedSource() }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func damagedSource() -> WakecupError {
        WakecupError(message: "The bundled helper is missing or damaged. Reinstall Wakecup.")
    }

    // shasum already depends on these system Perl modules. Opening once with
    // NOFOLLOW/NONBLOCK avoids path races and FIFO/device reads; both initial
    // size and streamed byte count are checked, including concurrent growth.
    // env -i below excludes Perl startup options/library paths from the caller.
    private static let boundedCopyProgram = #"""
    use strict;
    use warnings;
    sub reject_copy {
        print STDERR "The bundled helper is missing or damaged. Reinstall Wakecup.\n";
        exit($_[0] // 72);
    }
    @ARGV == 4 or reject_copy();
    my ($source, $stage, $expected, $maximum) = @ARGV;
    $maximum =~ /\A[0-9]+\z/ && $maximum > 0 && $maximum <= \#(HelperConstants.maximumExecutableBytes) or reject_copy();
    $expected =~ /\A[0-9a-f]{64}\z/ or reject_copy();
    sysopen(my $input, $source, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or reject_copy();
    my @source_info = stat($input);
    @source_info && S_ISREG($source_info[2]) && $source_info[7] > 0 && $source_info[7] <= $maximum or reject_copy();
    sysopen(my $output, $stage, O_WRONLY | O_NOFOLLOW | O_NONBLOCK) or reject_copy();
    my @stage_info = stat($output);
    @stage_info && S_ISREG($stage_info[2]) && $stage_info[3] == 1 && $stage_info[4] == $>
        && ($stage_info[2] & 0777) == 0600 && $stage_info[7] == 0 or reject_copy();
    my $digest = Digest::SHA->new(256);
    my $total = 0;
    while (1) {
        my $remaining = $maximum - $total + 1;
        my $length = $remaining < 65536 ? $remaining : 65536;
        my $count = sysread($input, my $buffer, $length);
        if (!defined($count)) { next if $! == EINTR; reject_copy(); }
        last if $count == 0;
        $count <= $maximum - $total or reject_copy();
        $total += $count;
        $digest->add($buffer);
        my $offset = 0;
        while ($offset < $count) {
            my $written = syswrite($output, $buffer, $count - $offset, $offset);
            if (!defined($written)) { next if $! == EINTR; reject_copy(); }
            $written > 0 or reject_copy();
            $offset += $written;
        }
    }
    $total > 0 or reject_copy();
    close($input) or reject_copy();
    close($output) or reject_copy();
    $digest->hexdigest eq $expected or reject_copy(71);
    """#

    static func stagingScript(source: URL, sha256: String, arguments: [String], detached: Bool) throws -> String {
        guard source.isFileURL, source.path.hasPrefix("/"), !source.path.utf8.contains(0),
              HelperPolicy.validHash(sha256, length: 64), !arguments.contains(where: { $0.utf8.contains(0) }) else {
            throw WakecupError(message: "Invalid administrator execution request.")
        }
        let invocation = "\"$stage\" " + arguments.map(shellQuote).joined(separator: " ")
        let execution = detached ? """
        (
          trap '/bin/rm -f "$stage"' EXIT
          \(invocation)
        ) > /dev/null 2>&1 < /dev/null &
        trap - EXIT
        """ : invocation
        return """
        set -eu
        check_dir() {
          [ -d "$1" ] && [ ! -L "$1" ] || exit 70
          case "$(/usr/bin/stat -f '%u:%Lp' "$1")" in
            0:1755|0:755|0:750|0:700|0:711|0:751|0:555|0:500) ;; *) exit 70 ;; esac
          acl_info=$(/bin/ls -lde "$1") || exit 70
          case "$acl_info" in *" allow "*) exit 70 ;; esac
        }
        check_dir /Library
        if [ ! -e /Library/PrivilegedHelperTools ] && [ ! -L /Library/PrivilegedHelperTools ]; then
          /bin/mkdir -m 755 /Library/PrivilegedHelperTools
        fi
        check_dir /Library/PrivilegedHelperTools
        stage=$(/usr/bin/mktemp /Library/PrivilegedHelperTools/.wakecup-stage-XXXXXXXX)
        trap '/bin/rm -f "$stage"' EXIT
        /bin/chmod -N "$stage"
        /usr/bin/env -i /usr/bin/perl -MFcntl=:DEFAULT,:mode -MDigest::SHA -MErrno=EINTR -e \(shellQuote(boundedCopyProgram)) -- \(shellQuote(source.path)) "$stage" \(shellQuote(sha256)) \(HelperConstants.maximumExecutableBytes)
        /bin/chmod 755 "$stage"
        \(execution)
        """
    }

    static func authorizationTask(script: String) -> Process {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "with timeout of 180 seconds\ndo shell script \"\(escaped)\" with administrator privileges\nend timeout"]
        return task
    }

    static func isStagedPath(_ path: String) -> Bool {
        let prefix = "/Library/PrivilegedHelperTools/.wakecup-stage-"
        guard path.hasPrefix(prefix) else { return false }
        let suffix = path.dropFirst(prefix.count)
        return suffix.utf8.count == 8 && suffix.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    static func validateStagedExecutable() throws {
        guard let path = try recoveryProcess(getpid())?.executable, isStagedPath(path),
              try HelperTrust.read(path, maximum: HelperConstants.maximumExecutableBytes, executable: true) != nil else {
            throw WakecupError(message: "The operation must run from a verified system staging file.")
        }
    }
}
