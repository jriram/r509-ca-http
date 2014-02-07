require 'sinatra/base'
require 'r509'
require "#{File.dirname(__FILE__)}/subjectparser"
require "#{File.dirname(__FILE__)}/validityperiodconverter"
require "#{File.dirname(__FILE__)}/factory"
require 'base64'
require 'yaml'
require 'logger'
require 'dependo'
require 'json'

module R509
  module CertificateAuthority
    module HTTP
      class Server < Sinatra::Base
        extend Dependo::Mixin
        include Dependo::Mixin

        configure do
          disable :protection #disable Rack::Protection (for speed)
          disable :logging
          set :environment, :production

          crls = {}
          certificate_authorities = {}
          options_builders = {}
          config_pool.names.each do |name|
            crls[name] = R509::CRL::Administrator.new(config_pool[name])
            options_builders[name] = R509::CertificateAuthority::OptionsBuilder.new(config_pool[name])
            certificate_authorities[name] = R509::CertificateAuthority::Signer.new(config_pool[name])
          end

          set :crls, crls
          set :certificate_authorities, certificate_authorities
          set :options_builders, options_builders
          set :subject_parser, R509::CertificateAuthority::HTTP::SubjectParser.new
          set :validity_period_converter, R509::CertificateAuthority::HTTP::ValidityPeriodConverter.new
          set :csr_factory, R509::CertificateAuthority::HTTP::Factory::CSRFactory.new
          set :spki_factory, R509::CertificateAuthority::HTTP::Factory::SPKIFactory.new
        end

        before do
          content_type :text
        end

        helpers do
          def crl(name)
            settings.crls[name]
          end
          def ca(name)
            settings.certificate_authorities[name]
          end
          def builder(name)
            settings.options_builders[name]
          end
          def subject_parser
            settings.subject_parser
          end
          def validity_period_converter
            settings.validity_period_converter
          end
          def csr_factory
            settings.csr_factory
          end
          def spki_factory
            settings.spki_factory
          end
        end

        error do
          log.error env["sinatra.error"].inspect
          log.error env["sinatra.error"].backtrace.join("\n")
          "Something is amiss with our CA. You should ... wait?"
        end

        error StandardError do
          log.error env["sinatra.error"].inspect
          log.error env["sinatra.error"].backtrace.join("\n")
          env["sinatra.error"].inspect
        end

        get '/favicon.ico' do
          log.debug "go away. no children."
          "go away. no children"
        end

        get '/1/crl/:ca/get/?' do
          log.info "DEPRECATED: Get CRL for #{params[:ca]}"

          if not crl(params[:ca])
            raise ArgumentError, "CA not found"
          end

          crl(params[:ca]).generate_crl.to_pem
        end

        get '/1/crl/:ca/generate/?' do
          log.info "Generate CRL for #{params[:ca]}"

          if not crl(params[:ca])
            raise ArgumentError, "CA not found"
          end

          crl(params[:ca]).generate_crl.to_pem
        end

        post '/1/p12/issue/?' do
          content_type :json

          log.info "Issue certificate and create a PKCS12 file"
          raw = request.env["rack.input"].read
          env["rack.input"].rewind
          log.info raw

          log.info params.inspect

          if not params.has_key?("ca")
            raise ArgumentError, "Must provide a CA"
          end
          if not ca(params["ca"])
            raise ArgumentError, "CA not found"
          end
          if not params.has_key?("profile")
            raise ArgumentError, "Must provide a CA profile"
          end
          if not params.has_key?("validityPeriod")
            raise ArgumentError, "Must provide a validity period"
          end

          subject = subject_parser.parse(raw, "subject")
          log.info subject.inspect
          log.info subject.to_s
          if subject.empty?
            raise ArgumentError, "Must provide a subject"
          end

          extensions = []
          if params.has_key?("extensions") and params["extensions"].has_key?("subjectAlternativeName")
            san_names = params["extensions"]["subjectAlternativeName"].select { |name| not name.empty? }
            if not san_names.empty?
              extensions.push(R509::Cert::Extensions::SubjectAlternativeName.new(:value => R509::ASN1.general_name_parser(san_names)))
            end
          elsif params.has_key?("extensions") and params["extensions"].has_key?("dNSNames")
            san_names = R509::ASN1::GeneralNames.new
            params["extensions"]["dNSNames"].select{ |name| not name.empty? }.each do |name|
              san_names.create_item(:tag => 2, :value => name.strip)
            end
            if not san_names.names.empty?
              extensions.push(R509::Cert::Extensions::SubjectAlternativeName.new(:value => san_names))
            end
          end

          validity_period = validity_period_converter.convert(params["validityPeriod"])

          log.info "Generate a private key" 
          key = R509::PrivateKey.new(:type => "RSA", :bit_length => 2048)

          log.info "Generate a certificate signing request" 
          csr = R509::CSR.new(
            :key => key,
            :subject => {
              :CN => subject["CN"],
              :O => subject["O"],
              :L => subject["L"],
              :ST => subject["ST"],
              :C => subject["C"]
            }
          )

          signer_opts = builder(params["ca"]).build_and_enforce(
            :csr => csr,
            :profile_name => params["profile"],
            :subject => subject,
            :extensions => extensions,
            :message_digest => params["message_digest"],
            :not_before => validity_period[:not_before],
            :not_after => validity_period[:not_after],
          )

          cert = ca(params["ca"]).sign(signer_opts)

          pem = cert.to_pem
          log.info pem

          cert = R509::Cert.new(:cert => cert, :key => key)
          cert.write_pkcs12("output.p12", "")

          pem
        end

        post '/1/certificate/issue/?' do
          log.info "Issue Certificate"
          raw = request.env["rack.input"].read
          env["rack.input"].rewind
          log.info raw

          log.info params.inspect

          if not params.has_key?("ca")
            raise ArgumentError, "Must provide a CA"
          end
          if not ca(params["ca"])
            raise ArgumentError, "CA not found"
          end
          if not params.has_key?("profile")
            raise ArgumentError, "Must provide a CA profile"
          end
          if not params.has_key?("validityPeriod")
            raise ArgumentError, "Must provide a validity period"
          end
          if not params.has_key?("csr") and not params.has_key?("spki")
            raise ArgumentError, "Must provide a CSR or SPKI"
          end

          subject = subject_parser.parse(raw, "subject")
          log.info subject.inspect
          log.info subject.to_s
          if subject.empty?
            raise ArgumentError, "Must provide a subject"
          end

          extensions = []
          if params.has_key?("extensions") and params["extensions"].has_key?("subjectAlternativeName")
            san_names = params["extensions"]["subjectAlternativeName"].select { |name| not name.empty? }
            if not san_names.empty?
              extensions.push(R509::Cert::Extensions::SubjectAlternativeName.new(:value => R509::ASN1.general_name_parser(san_names)))
            end
          elsif params.has_key?("extensions") and params["extensions"].has_key?("dNSNames")
            san_names = R509::ASN1::GeneralNames.new
            params["extensions"]["dNSNames"].select{ |name| not name.empty? }.each do |name|
              san_names.create_item(:tag => 2, :value => name.strip)
            end
            if not san_names.names.empty?
              extensions.push(R509::Cert::Extensions::SubjectAlternativeName.new(:value => san_names))
            end
          end

          validity_period = validity_period_converter.convert(params["validityPeriod"])

          if params.has_key?("csr")
            csr = csr_factory.build(:csr => params["csr"])
            signer_opts = builder(params["ca"]).build_and_enforce(
              :csr => csr,
              :profile_name => params["profile"],
              :subject => subject,
              :extensions => extensions,
              :message_digest => params["message_digest"],
              :not_before => validity_period[:not_before],
              :not_after => validity_period[:not_after],
            )
            cert = ca(params["ca"]).sign(signer_opts)
          elsif params.has_key?("spki")
            spki = spki_factory.build(:spki => params["spki"], :subject => subject)
            signer_opts = builder(params["ca"]).build_and_enforce(
              :spki => spki,
              :profile_name => params["profile"],
              :subject => subject,
              :extensions => extensions,
              :message_digest => params["message_digest"],
              :not_before => validity_period[:not_before],
              :not_after => validity_period[:not_after],
            )
            cert = ca(params["ca"]).sign(signer_opts)
          else
            raise ArgumentError, "Must provide a CSR or SPKI"
          end

          pem = cert.to_pem
          log.info pem

          pem
        end

        post '/1/certificate/revoke/?' do
          ca = params[:ca]
          serial = params[:serial]
          reason = params[:reason]
          log.info "Revoke for serial #{serial} on CA #{ca}"

          if not ca
            raise ArgumentError, "CA must be provided"
          end
          if not crl(ca)
            raise ArgumentError, "CA not found"
          end
          if not serial
            raise ArgumentError, "Serial must be provided"
          end

          if reason.nil? or reason.empty?
            reason = nil
          else
            reason = reason.to_i
          end

          crl(ca).revoke_cert(serial, reason)

          crl(ca).generate_crl.to_pem
        end

        post '/1/certificate/unrevoke/?' do
          ca = params[:ca]
          serial = params[:serial]
          log.info "Unrevoke for serial #{serial} on CA #{ca}"

          if not ca
            raise ArgumentError, "CA must be provided"
          end
          if not crl(ca)
            raise ArgumentError, "CA not found"
          end
          if not serial
            raise ArgumentError, "Serial must be provided"
          end

          crl(ca).unrevoke_cert(serial.to_i)

          crl(ca).generate_crl.to_pem
        end

        get '/test/certificate/issue/?' do
          log.info "Loaded test issuance interface"
          content_type :html
          erb :test_issue
        end

        get '/test/certificate/revoke/?' do
          log.info "Loaded test revoke interface"
          content_type :html
          erb :test_revoke
        end

        get '/test/certificate/unrevoke/?' do
          log.info "Loaded test unrevoke interface"
          content_type :html
          erb :test_unrevoke
        end
      end
    end
  end
end
