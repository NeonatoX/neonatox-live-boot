# Hooks System for mkinitramfs

## Overview

The hooks system allows adding custom functionality to the initramfs generation process without modifying the main `mkinitramfs` script. Hooks are executable scripts placed in specific directories that run at predetermined phases during initramfs creation.

## Hook Phases

| Phase | When | Purpose |
|-------|------|---------|
| `pre-binaries` | After creating basic structure, before copying binaries | Add custom binaries, libraries, or configurations |
| `pre-pack` | After all binaries copied, before cpio packaging | Modify files, add additional content |
| `pre-microcode` | Before embedding CPU microcode | Modify initramfs before microcode prepending |

## Hook Directory

Hooks must be placed in: `/usr/share/mkinitramfs/hooks/<phase>/`

```
/usr/share/mkinitramfs/hooks/
├── pre-binaries/
│   └── <hook-script>
├── pre-pack/
│   └── <hook-script>
└── pre-microcode/
    └── <hook-script>
```

## Hook Script Requirements

- Must be executable (`chmod +x`)
- Must accept **one argument**: the work directory path (WDIR)
- Must exit with **0** on success, non-zero on failure
- Should be written in POSIX shell (`#!/bin/sh`) for maximum compatibility

## Example Hooks

### Hook 01: Add early KMS driver

```sh
#!/bin/sh
# pre-binaries/01-kms - Load AMDGPU early

WDIR="$1"
[ -z "$WDIR" ] && exit 1

# Copy AMDGPU firmware for early loading
mkdir -p "$WDIR/usr/lib/firmware/amdgpu"
cp /usr/lib/firmware/amdgpu/*.bin "$WDIR/usr/lib/firmware/amdgpu/" 2>/dev/null || true

exit 0
```

### Hook 02: Add network support

```sh
#!/bin/sh
# pre-binaries/02-network - Include network drivers

WDIR="$1"
[ -z "$WDIR" ] && exit 1

# Include network binaries
for bin in ip dhclient; do
  if [ -x "/usr/sbin/$bin" ]; then
    cp "/usr/sbin/$bin" "$WDIR/usr/sbin/"
  fi
done

exit 0
```

### Hook 03: Custom init configuration

```sh
#!/sh
# pre-pack/03-custom-init - Add custom init configuration

WDIR="$1"
[ -z "$WDIR" ] && exit 1

# Add custom boot options
echo 'quiet loglevel=3' > "$WDIR/etc/bootopts"

exit 0
```

## Application Integration

### Adding Application Hooks

For applications that need to integrate with mkinitramfs:

1. **Create hook package**:
   ```
   /usr/share/mkinitramfs/hooks/
   └── pre-binaries/
       └── 50-myapp
   ```

2. **Hook script template**:
   ```sh
   #!/bin/sh
   WDIR="$1"
   
   # Your application logic here
   # Copy binaries, libraries, configs
   # Modify init scripts
   
   exit 0
   ```

3. **Install hooks**:
   - Via package manager (`.deb`, `.rpm`)
   - Via project-specific installer

### Application Examples

#### LVM with custom volume groups

```sh
#!/bin/sh
# pre-binaries/10-lvm-custom - LVM with specific VGs

WDIR="$1"

# Include LVM config with specific VGs
if [ -f /etc/lvm/lvm.conf ]; then
  mkdir -p "$WDIR/etc/lvm"
  cp /etc/lvm/lvm.conf "$WDIR/etc/lvm/"
fi

# Include only specific volume groups (optional)
# This reduces initramfs size by excluding unused VGs

exit 0
```

#### Crypto support (LUKS)

```sh
#!/bin/sh
# pre-binaries/20-crypt - LUKS/cryptsetup support

WDIR="$1"

# Include cryptsetup and its dependencies
for bin in cryptsetup; do
  if [ -x "/usr/sbin/$bin" ]; then
    cp "/usr/sbin/$bin" "$WDIR/usr/sbin/"
  fi
done

exit 0
```

#### Remote unlocking (SSH)

```sh
#!/bin/sh
# pre-binaries/30-dropbear - Dropbear SSH for remote unlock

WDIR="$1"

# Include Dropbear SSH
if [ -x /usr/sbin/dropbear ]; then
  mkdir -p "$WDIR/usr/sbin"
  cp /usr/sbin/dropbear "$WDIR/usr/sbin/"
  
  # Include authorized keys
  if [ -f /root/.ssh/authorized_keys ]; then
    mkdir -p "$WDIR/root/.ssh"
    cp /root/.ssh/authorized_keys "$WDIR/root/.ssh/"
  fi
fi

exit 0
```

## Hook Execution Order

- Hooks run in **lexicographical order** (alphabetical)
- Use numeric prefixes for control: `01-`, `02-`, `10-`, etc.
- Earlier hooks run before later hooks in the same phase

## Debugging Hooks

```bash
# Test hook manually
WDIR=/tmp/test-workdir
mkdir -p "$WDIR"
./my-hook "$WDIR"
echo "Exit code: $?"
```

## Best Practices

1. **Keep hooks small** - One task per hook
2. **Use numeric prefixes** - Control execution order
3. **Check dependencies** - Verify required files exist
4. **Fail gracefully** - Return 0 if feature not needed
5. **Document hooks** - Add comments explaining purpose

## Full Integration Example

Complete example for a system with LUKS, LVM, and Dropbear:

```
/usr/share/mkinitramfs/hooks/pre-binaries/
├── 01-kms          # GPU drivers
├── 10-lvm          # LVM support  
├── 20-crypt        # LUKS/cryptsetup
└── 30-dropbear    # SSH remote unlock

/usr/share/mkinitramfs/hooks/pre-pack/
└── 50-custom-init # Custom boot options
```

Each hook is responsible for copying its own binaries and dependencies to WDIR.