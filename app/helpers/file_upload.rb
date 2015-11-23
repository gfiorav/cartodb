# coding: utf-8

require 'rubygems'
require 'net/sftp'

module CartoDB
  class FileUpload

    DEFAULT_UPLOADS_PATH = 'public/uploads'
    FILE_ENCODING = 'utf-8'
    MAX_SYNC_UPLOAD_S3_FILE_SIZE = 52428800 # bytes

    def initialize(uploads_path = nil)
      @uploads_path = uploads_path || DEFAULT_UPLOADS_PATH
      unless @uploads_path[0] == "/"
        @uploads_path = Rails.root.join(@uploads_path)
      end
    end

    def get_uploads_path
      @uploads_path
    end

    def upload_file_to_storage(params, request, s3_config = nil, timestamp = Time.now)
      results = {
        file_uri: nil,
        enqueue:  true
      }
      # Used by cartodb chrome extension
      ajax_upload = false
      case
      when params[:filename].present? && request.body.present?
        filename = params[:filename].original_filename rescue params[:filename].to_s
        begin
          filepath = params[:filename].path
        rescue
          filepath = params[:filename].to_s
          ajax_upload = true
        end
      when params[:file].present?
        filename = params[:file].original_filename rescue params[:file].to_s
        filepath = params[:file].path rescue ''
      else
        return results
      end

      filename = filename.gsub(/ /, '_')

      random_token = Digest::SHA2.hexdigest("#{timestamp.utc}--#{filename.object_id.to_s}").first(20)

      use_s3 = !s3_config.nil? && s3_config['access_key_id'].present? && s3_config['secret_access_key'].present? &&
               s3_config['bucket_name'].present? && s3_config['url_ttl'].present?

      file = nil
      if ajax_upload
        file = save_body_to_file(params, request, random_token, filename)
        filepath = file.path
      end

      do_long_upload = s3_config['async_long_uploads'].present? && s3_config['async_long_uploads'] &&
        File.size(filepath) > MAX_SYNC_UPLOAD_S3_FILE_SIZE

      if use_s3 && !do_long_upload
        file_url = upload_file_to_s3(filepath, filename, random_token, s3_config)

        if ajax_upload
          File.delete(file.path)
        end

        results[:file_uri] = file_url
      else
        unless ajax_upload
          file = save_body_to_file(params, request, random_token, filename)
        end

        if use_s3 && do_long_upload
          results[:file_uri] = file.path[/(\/uploads\/.*)/, 1]
          results[:enqueue] = false
        else
          results[:file_uri] = file.path[/(\/uploads\/.*)/, 1]
        end
      end

      results
    end

    def upload_file_to_s3(filepath, filename, token, s3_config)
      AWS.config(
        access_key_id: s3_config['access_key_id'],
        secret_access_key: s3_config['secret_access_key']
      )
      s3_bucket = AWS::S3.new.buckets[s3_config['bucket_name']]

      path = "#{token}/#{File.basename(filename)}"
      o = s3_bucket.objects[path]

      o.write(Pathname.new(filepath), { acl: :authenticated_read })

      o.url_for(:get, expires: s3_config['url_ttl']).to_s
    end

    private

    def save_body_to_file(params, request, random_token, filename)
      case
      when params[:filename].present? && request.body.present?
        filedata = params[:filename]
      when params[:file].present?
        filedata = params[:file]
      else
        return
      end

      FileUtils.mkdir_p(get_uploads_path.join(random_token))

      if filedata.respond_to?(:tempfile)
        save_using_streaming(filedata, random_token, filename)
      else
        begin
          data = filedata.read.force_encoding(FILE_ENCODING)
        rescue
          data = request.body.read.force_encoding(FILE_ENCODING)
        end
        save(data, random_token, filename)
      end
    end

    def save(filedata, random_token, filename)
      file = File.new(get_uploads_path.join(random_token).join(File.basename(filename)), "w:#{FILE_ENCODING}")
      file.write filedata
      file.close
      CartoDB::Logger.info 'Inside upload_file_to_storage-save!!'
      check_call_remote_copy(random_token,filename)
      file
    end

    def save_using_streaming(filedata, random_token, filename)
      src = File.open(filedata.tempfile.path, "r:UTF-8")
      file = File.new(get_uploads_path.join(random_token).join(File.basename(filename)), 'w:UTF-8')
      IO.copy_stream(src, file)
      file.close
      src.close
      #Call for remote file copy
      CartoDB::Logger.info 'Inside upload_file_to_storage-save_using_streaming!!'
      check_call_remote_copy(random_token,filename)
      file
    end
    
    def check_call_remote_copy(random_token,filename)
      if Cartodb.config[:nfs_remote_usage]["is_usage"]
         mylocalhostname = `#{Cartodb.config[:nfs_remote_usage]["local_hostname_cmd"]}`
         if mylocalhostname[1] == 'j'
           copy_file_to_remote_filer(Cartodb.config[:nfs_remote_usage]["ny_pool"],Cartodb.config[:nfs_remote_usage]["ping_port"],Cartodb.config[:nfs_remote_usage]["user_name"],Cartodb.config[:nfs_remote_usage]["password"],Cartodb.config[:nfs_remote_usage]["connection_timeout"],filename,random_token)
         elsif mylocalhostname[1] == 'y'
           copy_file_to_remote_filer(Cartodb.config[:nfs_remote_usage]["nj_pool"],Cartodb.config[:nfs_remote_usage]["ping_port"],Cartodb.config[:nfs_remote_usage]["user_name"],Cartodb.config[:nfs_remote_usage]["password"],Cartodb.config[:nfs_remote_usage]["connection_timeout"],filename,random_token)
         else
           CartoDB::Logger.info 'Error:#{mylocalhostname} - 2nd character is not y or j!Skipping copying to remote filer!'
         end
      end
    end

    def copy_file_to_remote_filer(remote_host,remote_port,user_name,user_password,connection_timeout,filename,random_token)
     if ping(remote_host,remote_port)
       begin
         Net::SFTP.start(remote_host, user_name, :password => user_password, :timeout => connection_timeout) do |sftp|
           CartoDB::Logger.info  get_uploads_path.join(random_token).join(File.basename(filename)).to_s
           # create a directory
           sftp.mkdir! get_uploads_path.join(random_token)
           sftp.upload!(get_uploads_path.join(random_token).join(File.basename(filename)).to_s, get_uploads_path.join(random_token).join(File.basename(filename)).to_s)
           CartoDB::Logger.info 'Copy to Remote Filer was successful..'
         end
       rescue Timeout::Error
         CartoDB::Logger.info 'Error:Copy to Remote Filer timed out'
       resque
         CartoDB::Logger.info 'Error:Copy to Remote Filer was unsuccessful..'
       end
     else
         CartoDB::Logger.info 'Ping was not successful.. So skipping remote copy!!'
     end
    end

    def ping(host_name,remote_port)
        Net::Ping::TCP.econnrefused = true
        ping_obj = Net::Ping::TCP.new(host_name, remote_port, 1)
        if ping_obj.ping?
           return true
        else
           return false
        end
    end

  end
end
