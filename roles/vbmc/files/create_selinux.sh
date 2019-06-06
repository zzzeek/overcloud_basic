#!/bin/sh

# background:
# http://melikedev.com/2013/08/19/linux-selinux-semodule-compile-pp-module-from-te-file/
# https://www.centos.org/docs/5/html/Deployment_Guide-en-US/sec-sel-building-policy-module.html

# https://bugzilla.redhat.com/show_bug.cgi?id=1362244#c13

# $ setenforce permissive
# $ -> cd ~
# $ -> echo > /var/log/audit/audit.log # this ensures a clean log for analysis
# $ semodule -DB  # FROM THE BUGZILLA, TURN OFF DONTAUDIT RULES
# $ -> /etc/init.d/puppetmaster start # should show denials in log
# $ semodule -B, TURN BACK ON
# $ -> audit2allow -i /var/log/audit/audit.log -m puppetmaster # this will output the perms necessary for puppetmaster to access needed resources, copy and paste this into the file you are using in version control
# $ -> checkmodule -M -m -o puppetmaster.mod /path/to/your/version/controlled/puppetmaster.te # this will create a .mod file
# $ -> semodule_package -m puppetmaster.mod -o puppetmaster.pp # this will create a compiled semodule
# $ -> semodule -i puppetmaster.pp # this will install the module

virtualbmc=`semodule -l | grep virtualbmc`


if [[ $virtualbmc != '' ]]; then
  exit 0
fi

# generated by audit2allow
cat << EOF > /tmp/virtualbmc.te

module virtualbmc 1.0;

require {
	type init_t;
	type user_home_t;
	class file { open read unlink };
}

#============= init_t ==============
allow init_t user_home_t:file { open read unlink };

EOF


cd /tmp/
checkmodule -M -m -o virtualbmc.mod virtualbmc.te
semodule_package -m virtualbmc.mod -o virtualbmc.pp
semodule -i virtualbmc.pp
semodule -e virtualbmc




