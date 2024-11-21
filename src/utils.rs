use std::{
	collections::HashMap,
	fs::{self, File, OpenOptions},
	io::{self, Write, Seek, SeekFrom},
	path::Path,
	error::Error,
    };
use log::error;
use serde::{Deserialize, Serialize};
use std::process::Command;


    
#[derive(Debug, Serialize)]
pub struct PlatformPackage {
    pub name: String,
    pub kind: String,
    pub content: String,
    pub index: usize,
    pub package_type: String,
}
#[derive(Debug, Serialize, Deserialize)]
struct Namespace {
    #[serde(rename = "apiVersion")]
    api_version: String,
    kind: String,
    metadata: NamespaceMetadata,
}

#[derive(Debug, Serialize, Deserialize)]
struct NamespaceMetadata {
    #[serde(rename = "name")]
    name: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct ConfigMap {
    #[serde(rename = "apiVersion")]
    api_version: String,
    kind: String,
    metadata: Metadata,
}

#[derive(Debug, Serialize, Deserialize)]
struct Metadata {
    name: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct VolumeMount {
    #[serde(rename = "mountPath")]
    mount_path: String,
    name: String,
    #[serde(rename = "readOnly")]
    read_only: bool,
}

#[derive(Debug, Serialize, Deserialize)]
struct ConfigMapVolume {
    name: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct Volume {
    name: String,
    config_map: ConfigMapVolume,
}

#[derive(Debug, Serialize, Deserialize)]
struct Container {
    name: String,
    #[serde(rename = "volumeMounts")]
    volume_mounts: Vec<VolumeMount>,
}

#[derive(Debug, Serialize, Deserialize)]
struct PodSpec {
    containers: Vec<Container>,
    volumes: Vec<Volume>,
}

#[derive(Debug, Serialize, Deserialize)]
struct TemplateSpec {
    spec: PodSpec,
}

#[derive(Debug, Serialize, Deserialize)]
struct DeploymentTemplateSpec {
    selector: HashMap<String, String>,
    template: TemplateSpec,
}

#[derive(Debug, Serialize, Deserialize)]
struct DeploymentTemplate {
    #[serde(rename = "spec")]
    spec: DeploymentTemplateSpec,
}

#[derive(Debug, Serialize, Deserialize)]
struct DeploymentRuntimeConfig {
    #[serde(rename = "apiVersion")]
    api_version: String,
    kind: String,
    metadata: Metadata,
    spec: DeploymentTemplate,
}


#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Config {
    #[serde(rename = "helm-chart-name")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub helm_chart_name: Option<String>,
    #[serde(rename = "helm-url")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub helm_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub values: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secrets: Option<bool>,
    pub name: String,
    #[serde(rename = "helm-name")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub helm_name: Option<String>,
    #[serde(rename = "manifest-url")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manifest_url: Option<String>,
    #[serde(rename = "helm-version")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub helm_version: Option<String>,
    pub namespace: String,
    #[serde(rename = "sourcefile")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_file: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub filename: Option<String>,
    #[serde(rename = "crd-files")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub crd_files: Option<Vec<String>>,
    #[serde(rename = "secret-files")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secret_files: Option<Vec<String>>,
    #[serde(rename = "external-secret-files")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub external_secret_files: Option<Vec<String>>,
    #[serde(rename = "objectfiles")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub object_files: Option<Vec<String>>,
    #[serde(rename = "castname")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cast_name: Option<Vec<String>>,
    #[serde(rename = "namespace-files")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub namespace_files: Option<Vec<String>>,
}



pub fn should_skip_file(file_path: &Path) -> bool {
    if file_path.is_dir() {
        return true;
    }
    let content = match fs::read_to_string(file_path) {
        Ok(c) => c,
        Err(_) => return true,
    };
    content.contains("helm.sh/hook")
}



pub fn create_crossplane_object(config: &Config) -> Result<(), Box<dyn std::error::Error>> {
    const MAX_FILE_SIZE: usize = 300 * 1024; // 300 KB

    let mut file_indices = HashMap::new();
    file_indices.insert("crd", 1);
    file_indices.insert("namespace", 1);
    file_indices.insert("object", 1);
    file_indices.insert("secret", 1);
    file_indices.insert("externalsecret", 1);
    file_indices.insert("configmap", 1);

    let working_dir = format!("working/{}", config.name);
    let output_dir = "output";

    fs::create_dir_all(output_dir)?;

    let mut files: HashMap<String, File> = HashMap::new();

    for file_type in ["crd", "namespace", "object", "secret", "externalsecret", "configmap"] {
        let index = file_indices[file_type];
        let output_file = format!("{}/{}-{}-{}.yaml", output_dir, file_type, config.name, index);
        let file = OpenOptions::new().create(true).write(true).truncate(true).open(&output_file)?;
        files.insert(file_type.to_string(), file);
    }

    for entry in fs::read_dir(&working_dir)? {
        let entry = entry?;
        let file_path = entry.path();

        if should_skip_file(&file_path) {
            continue;
        }

        let file_name = file_path.file_name().unwrap().to_string_lossy();
        let content = fs::read_to_string(&file_path)?;

        let (current_file_type, current_file_index) = if file_name.contains("ConfigMap") {
            ("configmap", file_indices.get_mut("configmap").unwrap())
        } else if file_name.contains("CustomResourceDefinition") {
            ("crd", file_indices.get_mut("crd").unwrap())
        } else if file_name.contains("Namespace") {
            ("namespace", file_indices.get_mut("namespace").unwrap())
        } else if file_name.contains("ExternalSecret") {
            ("externalsecret", file_indices.get_mut("externalsecret").unwrap())
        } else if file_name.contains("Secret") {
            ("secret", file_indices.get_mut("secret").unwrap())
        } else {
            ("object", file_indices.get_mut("object").unwrap())
        };

        let current_file = files.get_mut(current_file_type).unwrap();
        let current_file_size = current_file.metadata()?.len() as usize;

        if current_file_size + content.len() > MAX_FILE_SIZE {
            *current_file_index += 1;
            let new_output_file = format!(
                "{}/{}-{}-{}.yaml",
                output_dir, current_file_type, config.name, current_file_index
            );
            *current_file = OpenOptions::new().create(true).write(true).truncate(true).open(&new_output_file)?;
        }

        if current_file_type == "configmap" {
            let config_map_content = format!(
                r#"
apiVersion: v1
kind: ConfigMap
metadata:
  name: {}-configmap
  namespace: crossplane-system
data:
  template: |
    {}
"#,
                file_name.trim_end_matches(".yaml"),
                content
            );

            writeln!(current_file, "{}", config_map_content)?;
        } else {
            writeln!(current_file, "---")?;
            writeln!(current_file, "{}", content)?;
        }
    }

    for file in files.values_mut() {
        file.sync_all()?;
    }

    Ok(())
}


pub fn generate_function_templates(output_dir: &str, new_file_path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let mut deployment_runtime_config = DeploymentRuntimeConfig {
        api_version: "pkg.crossplane.io/v1beta1".to_string(),
        kind: "DeploymentRuntimeConfig".to_string(),
        metadata: Metadata {
            name: "mount-templates".to_string(),
        },
        spec: DeploymentTemplate {
            spec: DeploymentTemplateSpec {
                selector: HashMap::new(),
                template: TemplateSpec {
                    spec: PodSpec {
                        containers: vec![Container {
                            name: "package-runtime".to_string(),
                            volume_mounts: Vec::new(),
                        }],
                        volumes: Vec::new(),
                    },
                },
            },
        },
    };

    for entry in fs::read_dir(output_dir)? {
        let entry = entry?;
        let path = entry.path();

        if let Some(ext) = path.extension() {
            if ext == "yaml" {
                let content = fs::read_to_string(&path)?;

                match serde_yaml::from_str::<ConfigMap>(&content) {
                    Ok(config_map) => {
                        if config_map.kind == "ConfigMap" {
                            let volume_mount = VolumeMount {
                                mount_path: format!("/templates/{}", config_map.metadata.name),
                                name: config_map.metadata.name.clone(),
                                read_only: true,
                            };
                            let volume = Volume {
                                name: config_map.metadata.name.clone(),
                                config_map: ConfigMapVolume {
                                    name: config_map.metadata.name.clone(),
                                },
                            };

                            if let Some(container) = deployment_runtime_config
                                .spec
                                .spec
                                .template
                                .spec
                                .containers
                                .first_mut()
                            {
                                container.volume_mounts.push(volume_mount);
                            }
                            deployment_runtime_config
                                .spec
                                .spec
                                .template
                                .spec
                                .volumes
                                .push(volume);
                        }
                    }
                    Err(e) => eprintln!("Error parsing ConfigMap file {:?}: {}", path, e),
                }
            }
        }
    }

    let yaml_content = serde_yaml::to_string(&deployment_runtime_config)?;
    fs::write(new_file_path, yaml_content)?;

    Ok(())
}



pub fn copy_yaml_files(src_dir: &str, dest_dir: &str) -> Result<(), Box<dyn std::error::Error>> {
    for entry in fs::read_dir(src_dir)? {
        let entry = entry?;
        let src_path = entry.path();

        if src_path.extension().and_then(|ext| ext.to_str()) == Some("yaml") {
            let dest_path = Path::new(dest_dir).join(src_path.file_name().unwrap());
            fs::copy(&src_path, &dest_path)?;
        }
    }

    Ok(())
}

pub fn remove_yaml_files(dir: &str) -> Result<(), Box<dyn std::error::Error>> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();

        if path.extension().and_then(|ext| ext.to_str()) == Some("yaml") {
            fs::remove_file(path)?;
        }
    }

    Ok(())
}

pub fn setup_logging() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::Builder::new()
        .filter_level(log::LevelFilter::Info)
        .format(|buf, record| writeln!(buf, "{}: {}", record.level(), record.args()))
        .target(env_logger::Target::Stderr)
        .init();
    Ok(())
}



pub fn template_helm(config: &Config) -> Result<(), Box<dyn Error>> {
    let filename = config.filename.clone().unwrap_or_else(|| format!("working/pre/{}.yaml", config.name));
    let mut file = File::create(&filename)?;

    if let Some(helm_url) = &config.helm_url {
        let helm_chart_name = config
            .helm_chart_name
            .as_ref()
            .ok_or_else(|| format!("Helm chart name is missing for {}", config.name))?;

        let helm_name = config
            .helm_name
            .as_ref()
            .ok_or_else(|| format!("Helm name is missing for {}", config.name))?;

        let mut cmd = Command::new("helm"); // Ensure `cmd` is of type `Command`
        cmd.arg("template")
            .arg(helm_name)
            .arg("--repo")
            .arg(helm_url)
            .arg(helm_chart_name);

        if let Some(version) = &config.helm_version {
            cmd.arg("--version").arg(version);
        }

        cmd.arg("--namespace").arg(&config.namespace);

        if let Some(values) = &config.values {
            cmd.arg("-f").arg(format!("input/{}/{}", config.name, values));
        }

        let output = cmd.output()?;

        if !output.status.success() {
            return Err(format!(
                "Helm command failed: {}",
                String::from_utf8_lossy(&output.stderr)
            )
            .into());
        }

        file.write_all(&output.stdout)?;
    } else {
        error!("No valid helm_url, source_file, or manifest_url for {}", config.name);
    }

    Ok(())
}


pub fn remove_empty_yaml_files(dir: &Path) -> io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.extension().map_or(false, |ext| ext == "yaml") {
            let metadata = fs::metadata(&path)?;
            if metadata.len() == 0 {
                fs::remove_file(&path)?;
            }
        }
    }
    Ok(())
}


pub fn validate_config(configs: &[Config]) -> Result<(), Box<dyn std::error::Error>> {
    for config in configs {
        if config.name.is_empty() {
            return Err(format!("Missing 'name' in config: {:?}", config).into());
        }

        if config.namespace.is_empty() {
            return Err(format!("Missing 'namespace' in config: {:?}", config).into());
        }

        if config.manifest_url.is_none()
            && config.helm_url.is_none()
            && config.source_file.is_none()
        {
            return Err(format!(
                "Either 'manifest-url', 'helm-url', or 'source-file' must be provided in config: {:?}",
                config
            )
            .into());
        }
    }
    Ok(())
}





pub fn load_config(path: &str) -> Result<Vec<Config>, Box<dyn std::error::Error>> {
    let file_content = fs::read_to_string(Path::new(path))?;

    log::debug!("Loaded YAML content: {}", file_content);

    let configs: Vec<Config> = serde_yaml::from_str(&file_content)?;

    validate_config(&configs)?;

    Ok(configs)
}






