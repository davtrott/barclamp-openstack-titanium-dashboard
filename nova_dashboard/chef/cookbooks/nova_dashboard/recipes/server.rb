# Copyright 2011 Dell, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe "apache2"
include_recipe "apache2::mod_wsgi"
include_recipe "apache2::mod_rewrite"

##################################### Ha code #######################################
# Retrieve virtual ip addresses from LoadBalancer
admin_vip = node[:haproxy][:admin_ip]
public_vip = node[:haproxy][:public_ip]
db_root_password = node["percona"]["server_root_password"]
Chef::Log.info(">>>>>> Nova Dashboard: Server Recipe admin vip: #{admin_vip}")
Chef::Log.info(">>>>>> Nova Dashboard: Server Recipe public vip: #{public_vip}")
Chef::Log.info(">>>>>> Nova Dashboard: Server Recipe db root password: #{db_root_password}")

my_ipaddress = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
Chef::Log.info(">>>>>> Nova Dashboard: Server Recipe my_ipaddress: #{my_ipaddress}")
######################################################################################

::Chef::Recipe.send(:include, Opscode::OpenSSL::Password)

dashboard_path = "/usr/share/openstack-dashboard"
venv_path = node[:nova_dashboard][:use_virtualenv] ? "#{dashboard_path}/.venv" : nil
venv_prefix = node[:nova_dashboard][:use_virtualenv] ? ". #{venv_path}/bin/activate &&" : nil

unless node[:nova_dashboard][:use_gitrepo]
  # Explicitly added client dependencies for now.
  packages = [ "openstack-dashboard", "python-novaclient", "python-glance", "python-swift", "python-keystone", "openstackx", "python-django", "python-django-horizon", "python-django-nose", "nodejs", "node-less" ]
  packages.each do |pkg|
    package pkg do
      action :install
    end
  end
  
  rm_pkgs = [ "openstack-dashboard-ubuntu-theme" ]
  rm_pkgs.each do |pkg|
    package pkg do
      action :purge
    end
  end
else
  pfs_and_install_deps "nova_dashboard" do
    path dashboard_path
    virtualenv venv_path
  end
  execute "chown_www-data" do
    command "chown -R www-data:www-data #{dashboard_path}"
  end
end


directory "#{dashboard_path}/.blackhole" do
  owner "www-data"
  group "www-data"
  mode "0755"
  action :create
end
  
directory "/var/www" do
  owner "www-data"
  group "www-data"
  mode "0755"
  action :create
end
  
apache_site "000-default" do
  enable false
end

template "#{node[:apache][:dir]}/sites-available/nova-dashboard.conf" do
  source "nova-dashboard.conf.erb"
  mode 0644
  variables(
    :horizon_dir => dashboard_path,
    :venv => node[:nova_dashboard][:use_virtualenv],
    :venv_path => venv_path,
		:my_ipaddress => my_ipaddress
  )
  if ::File.symlink?("#{node[:apache][:dir]}/sites-enabled/nova-dashboard.conf")
    notifies :reload, resources(:service => "apache2")
  end
end

if node[:nova_dashboard][:use_virtualenv]
  template "/usr/share/openstack-dashboard/openstack_dashboard/wsgi/django_venv.wsgi" do
    source "django_venv.wsgi.erb"
    mode 0644
    variables(
      :venv_path => venv_path
    )
  end
end

file "/etc/apache2/conf.d/openstack-dashboard.conf" do
  action :delete
end

apache_site "nova-dashboard.conf" do
  enable true
end

# Add a virtualhost entry in ports.conf if it doesn't exist
Chef::Log.info(">>>>>> Nova Dashboard: Add horizon virtual host entry in ports.conf ")
ports_conf_file = "/etc/apache2/ports.conf"
execute "add horizon virtual host command" do
  command "printf '\nListen #{my_ipaddress}:80\nNameVirtualHost #{my_ipaddress}:80' >> #{ports_conf_file}"
  not_if "grep #{my_ipaddress}:80 #{ports_conf_file}"
end

# nova_dashboard_service.rb now sets the password so that all nodes get the same password
node.set['dashboard']['db']['password'] = node[:nova_dashboard][:db][:password]

Chef::Log.info(">>>>>> Nova Dashboard: Database operations")

sql_address = admin_vip
url_scheme = "mysql"

::Chef::Recipe.send(:include, Opscode::OpenSSL::Password)

Chef::Log.info(">>>>>> Nova Dashboard: Database server found at #{sql_address}")

########################### DATABASE OPERATIONS ##############################
# create nova Dashboard - database, user and password using SQL template
template "/tmp/dashboard_grants.sql" do
  source "dashboard_grants.sql.erb"
  mode 0600
  variables(
    :dashboard_db_name => node[:dashboard][:db][:database],
    :dashboard_db_user => node[:dashboard][:db][:user],
    :dashboard_db_user_pwd => node[:dashboard][:db][:password]
  )
end

Chef::Log.info(">>>>>> Nova Dashboard: Executing SQL template")

# Execute SQL template
execute "mysql-install-privileges" do
  command "/usr/bin/mysql -u root -p#{db_root_password} < /tmp/dashboard_grants.sql"
  action :nothing
  subscribes :run, resources("template[/tmp/dashboard_grants.sql]"), :immediately
end

django_db_backend = "'django.db.backends.mysql'"
database_address = admin_vip

db_settings = {
      'ENGINE' => django_db_backend,
      'NAME' => "'#{node[:dashboard][:db][:database]}'",
      'USER' => "'#{node[:dashboard][:db][:user]}'",
      'PASSWORD' => "'#{node[:dashboard][:db][:password]}'",
      'HOST' => "'#{database_address}'",
      'default-character-set' => "'utf8'"
    }
########################### END DATABASE OPERATIONS ##########################

# Need to figure out environment filter
env_filter = " AND keystone_config_environment:keystone-config-#{node[:nova_dashboard][:keystone_instance]}"
keystones = search(:node, "recipes:keystone\\:\\:server#{env_filter}") || []
if keystones.length > 0
  keystone = keystones[0]
  keystone = node if keystone.name == node.name
else
  keystone = node
end

if node[:nova_dashboard][:use_gitrepo]
  pfs_and_install_deps "keystone" do
    cookbook "keystone"
    cnode keystone
  end
end

# Keystone address must be admin_vip
keystone_address = admin_vip
keystone_service_port = keystone["keystone"]["api"]["service_port"] rescue nil
Chef::Log.info("Keystone server found at #{keystone_address}")

execute "python manage.py syncdb" do
  cwd dashboard_path
  environment ({'PYTHONPATH' => dashboard_path})
  command "#{venv_prefix} python manage.py syncdb --noinput"
  user "www-data"
  action :nothing
  notifies :restart, resources(:service => "apache2"), :immediately
end

# Need to template the "EXTERNAL_MONITORING" array
template "#{dashboard_path}/openstack_dashboard/local/local_settings.py" do
  source "local_settings.py.erb"
  owner "root"
  group "root"
  mode "0644"
  variables(
    :keystone_address => keystone_address,
    :keystone_service_port => keystone_service_port,
    :db_settings => db_settings
  )
  notifies :run, resources(:execute => "python manage.py syncdb"), :immediately
  action :create
end

node[:nova_dashboard][:monitor][:svcs] <<["nova_dashboard-server"]
node.save

