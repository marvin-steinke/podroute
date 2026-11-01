def ipv4:
  type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$") and
  (split(".") | all(.[]; (tonumber >= 0 and tonumber <= 255) and ((tonumber | tostring) == .)));
def cidr:
  type == "string" and (split("/") as $parts | ($parts | length) == 2 and
    ($parts[0] | ipv4) and ($parts[1] | test("^([1-9]|[12][0-9]|3[0-2])$")) and
    (($parts[0] | reduce (split(".")[] | tonumber) as $octet (0; . * 256 + $octet)) % pow(2; 32 - ($parts[1] | tonumber)) == 0));
def integer($min; $max): type == "number" and floor == . and . >= $min and . <= $max;
def domain: type == "string" and length <= 253 and test("^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\\.?$");
def unicast: ipv4 and . != "0.0.0.0" and (split(".")[0] | tonumber != 127) and . != "255.255.255.255" and (split(".")[0] | tonumber < 224 or tonumber >= 240);
def id: type == "string" and test("^[a-z0-9][a-z0-9.-]{0,62}$");
def forwarding:
  (keys - ["protocol","externalPort","targetPort"] | length == 0) and
  (.protocol == "tcp" or .protocol == "udp") and
  (.externalPort | integer(1;65535)) and (.targetPort | integer(1;65535));
def static_client($network; $start):
  (keys - ["id","address","ports"] | length == 0) and (.id | id) and
  (.address | ipv4 and startswith($network + ".") and (split(".")[3] | tonumber >= 2 and tonumber < $start)) and
  ((.ports // []) | type == "array" and all(.[]; forwarding));
def defaults: {
  overlayCIDR:"172.16.1.0/24",vxlanID:42,vxlanPort:4789,vpnInterface:"wg0",
  vpnProtocol:"udp",vpnPort:51820,vpnEndpointCIDRs:[],clientBypassCIDRs:[],gatewayBypassCIDRs:[],
  clusterDomain:"cluster.local",localDomains:[],dnssec:true,upstreamDNS:["1.1.1.1","9.9.9.9"],
  dhcpStart:20,mtu:0,retrySeconds:10,staticClients:[]
};
def validate:
  . as $config |
  (.overlayCIDR | split("/")[0] | split(".")[0:3] | join(".")) as $network |
  (keys - ["gatewayHost","overlayCIDR","vxlanID","vxlanPort","vpnInterface","vpnProtocol","vpnPort","vpnEndpointCIDRs","clientBypassCIDRs","gatewayBypassCIDRs","clusterDNS","clusterDomain","localDomains","upstreamDNS","dnssec","dhcpStart","mtu","retrySeconds","staticClients"] | length == 0) and
  (.gatewayHost | domain) and (.clusterDomain | domain) and
  (.gatewayHost | if test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$") then unicast and (startswith($network + ".") | not) else true end) and
  (.overlayCIDR | cidr and test("\\.0/24$")) and
  (.vxlanID | integer(1;16777215)) and (.vxlanPort | integer(1;65535)) and
  (.vpnInterface | type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,14}$") and . != "eth0" and . != "vxlan0" and . != "lo") and
  (.vpnProtocol == "udp" or .vpnProtocol == "tcp") and (.vpnPort | integer(1;65535)) and
  (.dhcpStart | integer(3;254)) and (.mtu == 0 or (.mtu | integer(576;9000))) and
  (.retrySeconds | integer(1;300)) and (.dnssec | type == "boolean") and
  ([.clientBypassCIDRs,.gatewayBypassCIDRs,.vpnEndpointCIDRs] | all(.[]; type == "array" and all(.[]; cidr))) and
  (.localDomains | type == "array" and all(.[]; domain)) and
  (.clusterDNS | type == "array" and length > 0 and all(.[]; unicast and (startswith($network + ".") | not))) and
  (.upstreamDNS | type == "array" and length > 0 and all(.[]; unicast and (startswith($network + ".") | not))) and
  ([.clusterDNS[],.upstreamDNS[]] | length == (unique | length)) and
  (.staticClients | type == "array" and all(.[]; static_client($network; $config.dhcpStart))) and
  ([.staticClients[].id] | length == (unique | length)) and
  ([.staticClients[].address] | length == (unique | length)) and
  ([.staticClients[] | .ports[]? | [.protocol,.externalPort]] | length == (unique | length));
if type != "object" then error("network profile must be an object") else defaults + . end |
if validate then . else error("invalid PodRoute network profile") end