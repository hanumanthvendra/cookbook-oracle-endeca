###
# Check requirements
###
raise "Installation files must be provided! Please set 'endeca.install.mdex' attribute" if node[:endeca][:install][:mdex].empty?
raise "Installation files must be provided! Please set 'endeca.install.platform' attribute" if node[:endeca][:install][:platform].empty?
raise "Installation files must be provided! Please set 'endeca.install.tools' attribute" if node[:endeca][:install][:tools].empty?
raise "Installation files must be provided! Please set 'endeca.install.cas' attribute" if node[:endeca][:install][:cas].empty?

bash "check #{node[:endeca][:root_dir]} > 10G" do
  code "df -P #{node[:endeca][:root_dir]} | awk '/\\//{if ($2/1024/1024 < 10) exit 1}'"
end

group "oinstall"
user "oracle" do
  group "oinstall"
end

node.set[:java][:jdk_version] = "7"
node.set[:java][:install_flavor] = "oracle"
node.set[:java][:oracle][:accept_oracle_download_terms] = true
include_recipe "java"

package "unzip"
package "libaio"

directory ::File.join(node[:endeca][:root_dir], "endeca") do
  owner "oracle"
  group "oinstall"
end

file "/etc/oraInst.loc" do
  content <<-EEND
inventory_loc=#{node[:endeca][:root_dir]}/endeca/oraInventory
inst_group=oinstall
  EEND
end

###
# Download installers
###
files = {
  "mdex" => ::File.join(node[:endeca][:install_dir], ::File.basename(node[:endeca][:install][:mdex])),
  "platform" => ::File.join(node[:endeca][:install_dir], ::File.basename(node[:endeca][:install][:platform])),
  "tools" => ::File.join(node[:endeca][:install_dir], ::File.basename(node[:endeca][:install][:tools])),
  "cas" => ::File.join(node[:endeca][:install_dir], ::File.basename(node[:endeca][:install][:cas]))
}

files.keys.each do |f|
  remote_file files[f] do
    source node[:endeca][:install][f]
    retries 2
    use_conditional_get true
    use_etag true
    use_last_modified true
    action :create_if_missing
  end
end

###
# Install MDEX
###
bash "install MDEX" do
  user "oracle"
  group "oinstall"
  cwd node[:endeca][:install_dir]
  code <<-EEND
    unzip -u -o #{files["mdex"]} && ./OCmdex*.sh --target #{node[:endeca][:root_dir]} && touch #{files["mdex"]}.installed
  EEND
  only_if { ::File.exists?(files["mdex"]) }
  not_if { ::File.exists?(files["mdex"]+".installed") }
end

###
# Install Platform
###
bash "install Platform" do
  user "oracle"
  group "oinstall"
  cwd node[:endeca][:install_dir]
  code <<-EEND
    source #{node[:endeca][:root_dir]}/endeca/MDEX/6.5.1/mdex_setup_sh.ini
    unzip -u -o #{files["platform"]} && sh ./OCplatform*.bin --target #{node[:endeca][:root_dir]} --noprompt && touch #{files["platform"]}.installed
  EEND
  only_if { ::File.exists?(files["platform"]) }
  not_if { ::File.exists?(files["platform"]+".installed") }
end

bash "fix eac.properties" do
  user "oracle"
  group "oinstall"
  code <<-EEND
    sed -i -e "s#^com.endeca.mdexRoot=.*#com.endeca.mdexRoot=#{node[:endeca][:root_dir]}/endeca/MDEX/6.5.1#" #{node[:endeca][:root_dir]}/endeca/PlatformServices/workspace/conf/eac.properties
  EEND
end

file "#{node[:endeca][:root_dir]}/endeca/PlatformServices/workspace/conf/eaccmd.properties" do
  owner "oracle"
  group "oinstall"
  mode "0644"
  content <<-EEND
host=localhost
port=8888
  EEND
end

template "/etc/init.d/endeca_platform" do
  mode "0755"
  variables({
    :endeca_user => "oracle",
    :platform_path => "#{node[:endeca][:root_dir]}/endeca/PlatformServices"
  })
end

# Start Platform services
service "endeca_platform" do
  action [ :enable, :start ]
end

# wait for Platform startup
remote_file "wait Platform startup" do
  path "/tmp/platform.dummy"
  source "http://localhost:8888/eac-agent/FileListService?wsdl"
  retries 60
  retry_delay 10
  backup false
end

###
# Install Tools
###
bash "install Tools" do
  user "oracle"
  group "oinstall"
  cwd node[:endeca][:install_dir]
  code <<-EEND
    source #{node[:endeca][:root_dir]}/endeca/MDEX/6.5.1/mdex_setup_sh.ini
    source #{node[:endeca][:root_dir]}/endeca/PlatformServices/workspace/setup/installer_sh.ini
    unzip -u -o #{files["tools"]}
    cd ./cd/Disk1/install
    export ENDECA_TOOLS_ROOT=#{node[:endeca][:root_dir]}/endeca/Tools/11.1.0
    export ENDECA_TOOLS_CONF=#{node[:endeca][:root_dir]}/endeca/Tools/11.1.0/server/workspace
    sh ./silent_install.sh `pwd`/silent_response.rsp TOOLS #{node[:endeca][:root_dir]}/endeca/Tools admin | tee #{node[:endeca][:install_dir]}/tools.log
    rm -rf #{node[:endeca][:root_dir]}/endeca/Tools/11.1.0/server/workspace/state/sling
    grep SEVERE #{node[:endeca][:install_dir]}/tools.log || touch  #{files["tools"]}.installed
  EEND
  only_if { ::File.exists?(files["tools"]) }
  not_if { ::File.exists?(files["tools"]+".installed") }
end

template "/etc/init.d/endeca_workbench" do
  mode "0755"
  variables({
    :endeca_user => "oracle",
    :tools_path => "#{node[:endeca][:root_dir]}/endeca/Tools"
  })
end

bash "path workbench.sh" do
  user "oracle"
  group "oinstall"
  code <<-EEND
    sed -i -e 's/" stop/" stop 30 -force/' #{node[:endeca][:root_dir]}/endeca/Tools/11.1.0/server/bin/workbench.sh
  EEND
  not_if "grep '\" -force' #{node[:endeca][:root_dir]}/endeca/Tools/11.1.0/server/bin/workbench.sh"
end

# Start Workbench service
service "endeca_workbench" do
  action [ :enable, :start ]
end

# wait for Workbench startup
remote_file "wait Workbench startup" do
  path "/tmp/workbench.dummy"
  source "http://localhost:8006/"
  retries 60
  retry_delay 10
  backup false
end

###
# Install CAS
###
bash "install CAS" do
  user "oracle"
  group "oinstall"
  cwd node[:endeca][:install_dir]
  code <<-EEND
    unzip -u -o #{files["cas"]} && \
    echo -e "8500\n8506\n`hostname -f`" | sh OCcas*.sh --target /opt --endeca_tools_root /opt/endeca/Tools/11.1.0 --endeca_tools_conf /opt/endeca/Tools/11.1.0/server/workspace && \
    touch #{files["cas"]}.installed
  EEND
  only_if { ::File.exists?(files["cas"]) }
  not_if { ::File.exists?(files["cas"]+".installed") }
  notifies :restart, "service[endeca_workbench]", :immediate
end

template "/etc/init.d/endeca_cas" do
  mode "0755"
  variables({
    :endeca_user => "oracle",
    :cas_path => "#{node[:endeca][:root_dir]}/endeca/CAS"
  })
end

# Start CAS service
service "endeca_cas" do
  action [ :enable, :start ]
end
