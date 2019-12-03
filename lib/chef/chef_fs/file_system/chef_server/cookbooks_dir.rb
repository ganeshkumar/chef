#
# Author:: John Keiser (<jkeiser@chef.io>)
# Copyright:: Copyright 2012-2016, Chef Software Inc.
# License:: Apache License, Version 2.0
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

require_relative "rest_list_dir"
require_relative "cookbook_dir"
require_relative "../exceptions"
require_relative "../repository/chef_repository_file_system_cookbook_dir"
require_relative "../../../mixin/file_class"

require "tmpdir" unless defined?(Dir.mktmpdir)

class Chef
  module ChefFS
    module FileSystem
      module ChefServer
        #
        # /cookbooks
        #
        # Example children:
        #   apache2/
        #   mysql/
        #
        class CookbooksDir < RestListDir

          include Chef::Mixin::FileClass

          def make_child_entry(name)
            result = @children.find { |child| child.name == name } if @children
            result || CookbookDir.new(name, self)
          end

          def children
            @children ||= begin
              result = root.get_json(api_path).keys.map { |cookbook_name| CookbookDir.new(cookbook_name, self, exists: true) }
              result.sort_by(&:name)
            end
          end

          def create_child_from(other, options = {})
            @children = nil
            upload_cookbook_from(other, options)
          end

          def upload_cookbook_from(other, options = {})
            upload_cookbook(other, options)
          rescue Timeout::Error => e
            raise Chef::ChefFS::FileSystem::OperationFailedError.new(:write, self, e, "Timeout writing: #{e}")
          rescue Net::HTTPClientException => e
            case e.response.code
            when "409"
              raise Chef::ChefFS::FileSystem::CookbookFrozenError.new(:write, self, e, "Cookbook #{other.name} is frozen")
            else
              raise Chef::ChefFS::FileSystem::OperationFailedError.new(:write, self, e, "HTTP error writing: #{e}")
            end
          rescue Chef::Exceptions::CookbookFrozen => e
            raise Chef::ChefFS::FileSystem::CookbookFrozenError.new(:write, self, e, "Cookbook #{other.name} is frozen")
          end

          def upload_cookbook(other, options)
            compiled_metadata = other.chef_object.compile_metadata

            Dir.mktmpdir do |tmp_dir_path|
              begin
                if compiled_metadata
                  proxy_cookbook_path = "#{tmp_dir_path}/#{other.name}"
                  # Make a symlink
                  file_class.symlink other.chef_object.root_dir, proxy_cookbook_path
                  proxy_loader = Chef::Cookbook::CookbookVersionLoader.new(proxy_cookbook_path)
                  proxy_loader.load_cookbooks
                  cookbook_to_upload = proxy_loader.cookbook_version
                else
                  cookbook_to_upload = other.chef_object
                end

                cookbook_to_upload.freeze_version if options[:freeze]
                uploader = Chef::CookbookUploader.new(cookbook_to_upload, force: options[:force], rest: chef_rest)

                with_actual_cookbooks_dir(other.parent.file_path) do
                  uploader.upload_cookbooks
                end
              ensure
                # deletes the generated metadata from local repo.
                if compiled_metadata
                  GC.start
                  File.unlink(compiled_metadata)
                end
              end
            end
          end

          def chef_rest
            Chef::ServerAPI.new(root.chef_rest.url, root.chef_rest.options.merge(version_class: Chef::CookbookManifestVersions))
          end

          # Work around the fact that CookbookUploader doesn't understand chef_repo_path (yet)
          def with_actual_cookbooks_dir(actual_cookbook_path)
            old_cookbook_path = Chef::Config.cookbook_path
            Chef::Config.cookbook_path = actual_cookbook_path unless Chef::Config.cookbook_path

            yield
          ensure
            Chef::Config.cookbook_path = old_cookbook_path
          end

          def can_have_child?(name, is_dir)
            is_dir
          end
        end
      end
    end
  end
end
