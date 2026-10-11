require 'aws-sdk-s3'

# Read-only access to the photos in the asxpio bucket.
module S3
  module_function

  def client
    @client ||= Aws::S3::Client.new(
      region:            ENV.fetch('S3_REGION', 'us-east-1'),
      endpoint:          ENV.fetch('S3_ENDPOINT'),
      access_key_id:     ENV.fetch('S3_ACCESS_KEY'),
      secret_access_key: ENV.fetch('S3_SECRET_KEY'),
      force_path_style:  true
    )
  end

  def get(key)
    client.get_object(bucket: ENV.fetch('S3_BUCKET'), key: key).body.read.b # body is a UTF-8 StringIO
  end
end
