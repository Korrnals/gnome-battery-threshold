# Minimal binary kmod spec for acpi_call.
#
# Used by the Makefile to package a pre-built acpi_call.ko for the running
# kernel on rpm-ostree atomic systems (Silverblue/Kinoite/Sericea) where DKMS
# cannot run inside the compose sandbox. Invoke with:
#
#   rpmbuild -bb data/rpm/acpi_call-kmod.spec \
#       --define "kver $(uname -r)" \
#       --define "_sourcedir <dir-containing-acpi_call.ko>" \
#       --define "_topdir <rpmbuild-tree>"

%global kmod_name    acpi_call
%global kmod_version 1.2.0
%{!?kver: %global kver %(uname -r)}

# Skip the strip/debug pipeline — we're shipping a single pre-built .ko.
%global debug_package %{nil}
%global __os_install_post %{nil}
%global __strip /bin/true

Name:      %{kmod_name}-kmod-%{kver}
Version:   %{kmod_version}
Release:   1%{?dist}
Summary:   acpi_call kernel module built for %{kver}
License:   GPLv3
URL:       https://github.com/nix-community/acpi_call
Source0:   acpi_call.ko

BuildArch: x86_64
Provides:  acpi_call = %{version}-%{release}
Provides:  kmod-acpi_call = %{version}-%{release}
Requires:  kernel-uname-r = %{kver}
Requires(post):   /usr/sbin/depmod
Requires(postun): /usr/sbin/depmod

%description
The acpi_call kernel module compiled out-of-tree for kernel %{kver}.
Exposes /proc/acpi/call so userspace can invoke ACPI methods. Used by the
battery-threshold daemon to set charge-control thresholds on hardware
(e.g. Xiaomi laptops) that exposes those controls via ACPI rather than
sysfs.

%prep
# nothing

%build
# nothing

%install
install -Dm644 %{SOURCE0} %{buildroot}/usr/lib/modules/%{kver}/extra/acpi_call.ko

%post
/usr/sbin/depmod -a %{kver} || :

%postun
/usr/sbin/depmod -a %{kver} || :

%files
/usr/lib/modules/%{kver}/extra/acpi_call.ko

%changelog
* Wed May 20 2026 battery-threshold <none> 1.2.0-1
- Initial pre-built kmod packaging for atomic Fedora.
