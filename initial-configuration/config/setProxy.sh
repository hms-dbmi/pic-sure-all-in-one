############################################################
### BEGIN: Configuration
# Proxy Server (Ex: proxy.internal.com)
proxyServer=""
# Proxy Port (Ex: 80)
proxyPort=""
# Proxy Protocol (https or http)
proxyProto=""
# Proxy Authentication
proxyUser=""
proxyPass=""
# List of hosts that bypass the proxy
noProxy="localhost,127.0.0.1,wildfly,httpd,hpds"
### END: Configuration
############################################################

if [ -n "$proxyServer" ]; then
	# Use default port 80
	if [ -z "$proxyPort" ]; then
		proxyPort="80"
	fi
	if [ -z "$proxyProto" ] && ([ "$proxyPort" = "443" ] || [ "$proxyPort" = "8443" ]); then
		proxyProto="https"
	fi

	if [ -n "$proxyUser" ] && [ -n "$proxyPass" ]; then
		proxyAuthPrefix="$proxyUser:$proxyPass@"
	else
		proxyAuthPrefix=""
	fi

	## Standard Environment Variables in Linux
	export HTTP_PROXY="$proxyProto://$proxyAuthPrefix$proxyServer:$proxyPort"
	export HTTPS_PROXY="$proxyProto://$proxyAuthPrefix$proxyServer:$proxyPort"
	export NO_PROXY="$noProxy"
	export http_proxy="$proxyProto://$proxyAuthPrefix$proxyServer:$proxyPort"
	export https_proxy="$proxyProto://$proxyAuthPrefix$proxyServer:$proxyPort"
	export no_proxy="$noProxy"

	noProxyPipes=$(echo $noProxy | sed "s/,/|/g")

	## Custom Variable for Java
	proxyOpts="-Dhttp.proxyHost=$proxyServer -Dhttp.proxyPort=$proxyPort -Dhttp.proxyUser=$proxyUser -Dhttp.proxyPassword=$proxyPass"
	proxyOpts="$proxyOpts -Dhttps.proxyHost=$proxyServer -Dhttps.proxyPort=$proxyPort -Dhttps.proxyUser=$proxyUser -Dhttps.proxyPassword=$proxyPass"
	proxyOpts="$proxyOpts -Dhttp.nonProxyHosts='$noProxyPipes'"
	export PROXY_OPTS="$proxyOpts"
fi