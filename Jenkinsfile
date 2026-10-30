// Delete previous containers and networks created by this build (labelled with BUILD_TAG).
def ciClean() {
    sh '''
        docker ps -aq --filter "label=ci-build=${BUILD_TAG}" | xargs -r docker rm -f > /dev/null 2>&1 || true
        docker network ls -q --filter "label=ci-build=${BUILD_TAG}" | xargs -r docker network rm > /dev/null 2>&1 || true
    '''
}

def ciNet(String suffix) {
    return ('ci-' + env.BUILD_NUMBER + '-' + suffix)
}

// Write new image tags in the manifests repo, create namespace and secret (if needed), request ArgoCD to sync and wait for the application to be "Healthy".
def promote(String envName) {
    withEnv(["ENV_NAME=${envName}", "APP_NAME=fastapi-${envName}"]) {
        withCredentials([
            file(credentialsId: 'kubeconfig-cluster', variable: 'KUBECONFIG'),
            usernamePassword(credentialsId: 'github-manifests', usernameVariable: 'GIT_USER', passwordVariable: 'GIT_TOKEN'),
            string(credentialsId: "postgres-user-${envName}", variable: 'POSTGRES_USER'),
            string(credentialsId: "postgres-password-${envName}", variable: 'POSTGRES_PASSWORD'),
            string(credentialsId: "first-superuser-password-${envName}", variable: 'FIRST_SUPERUSER_PASSWORD'),
            string(credentialsId: "fastapi-secret-key-${envName}", variable: 'SECRET_KEY')
        ]) {
            sh '''
                set -eu
                set +x
                kubectl get nodes > /dev/null          # échouer AVANT toute modification si le cluster est injoignable

                rm -rf "manifests-$ENV_NAME"
                AUTH="Authorization: Basic $(printf '%s:%s' "$GIT_USER" "$GIT_TOKEN" | base64 -w0)"
                git_m() { git -c "http.extraheader=$AUTH" "$@"; }

                git_m clone --depth 1 --branch "$MANIFESTS_BRANCH" "$MANIFESTS_REPO_URL" "manifests-$ENV_NAME"
                cd "manifests-$ENV_NAME"

                bash "$WORKSPACE/ci/set-image-tag.sh" "chart/envs/values-$ENV_NAME.yaml" "$BACKEND_TAG" "$FRONTEND_TAG"
                helm lint chart -f "chart/envs/values-$ENV_NAME.yaml"      # ne jamais pousser un chart cassé

                git config user.name  "jenkins-ci"
                git config user.email "jenkins-ci@apiforge.local"
                if git diff --quiet; then
                    echo "Tags déjà à jour dans Git pour $ENV_NAME : pas de nouveau commit."
                else
                    git commit -am "ci($ENV_NAME): $BACKEND_TAG / $FRONTEND_TAG (build $BUILD_NUMBER)"
                    for i in 1 2 3; do
                        git_m push origin "$MANIFESTS_BRANCH" && break
                        git_m pull --rebase origin "$MANIFESTS_BRANCH"
                        [ "$i" = 3 ] && { echo "Push impossible après 3 essais" >&2; exit 1; }
                    done
                fi
                git rev-parse HEAD > "$WORKSPACE/.manifests-sha-$ENV_NAME"
            '''

            sh '''
                set -eu
                set +x
                umask 077
                ENVFILE=$(mktemp)
                trap 'rm -f "$ENVFILE"' EXIT
                {
                    printf 'POSTGRES_USER=%s\n' "$POSTGRES_USER"
                    printf 'POSTGRES_PASSWORD=%s\n' "$POSTGRES_PASSWORD"
                    printf 'POSTGRES_DB=%s\n' "fastapi"
                    printf 'SECRET_KEY=%s\n' "$SECRET_KEY"
                    printf 'FIRST_SUPERUSER_PASSWORD=%s\n' "$FIRST_SUPERUSER_PASSWORD"
                } > "$ENVFILE"

                kubectl create namespace "$ENV_NAME" --dry-run=client -o yaml | kubectl apply -f -
                kubectl -n "$ENV_NAME" create secret generic db-secret \
                    --from-env-file="$ENVFILE" --dry-run=client -o yaml | kubectl apply -f -

                # Idempotent : crée l'Application si elle n'existe pas (premier passage, ou après un nettoyage)
                kubectl apply -f "manifests-$ENV_NAME/applications/$ENV_NAME.yaml"
            '''

            sh '''
                set -eu
                set +x
                SHA=$(cat "$WORKSPACE/.manifests-sha-$ENV_NAME")
                A="kubectl -n argocd"

                # ArgoCD interroge Git toutes les 3 minutes : on force la lecture
                $A annotate application "$APP_NAME" argocd.argoproj.io/refresh=hard --overwrite

                if [ "$ENV_NAME" = "prod" ]; then
                    # Pas de synchronisation automatique en production : on la déclenche, après validation humaine
                    $A patch application "$APP_NAME" --type merge \
                        -p "{\\"operation\\":{\\"initiatedBy\\":{\\"username\\":\\"jenkins\\"},\\"sync\\":{\\"revision\\":\\"$SHA\\"}}}" || true
                fi

                for i in $(seq 1 120); do
                    REV=$($A get application "$APP_NAME" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)
                    SYNC=$($A get application "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
                    HEALTH=$($A get application "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)
                    PHASE=$($A get application "$APP_NAME" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)
                    OPREV=$($A get application "$APP_NAME" -o jsonpath='{.status.operationState.syncResult.revision}' 2>/dev/null || true)
                    echo "[$i/120] $APP_NAME révision=$(printf '%.8s' "$REV") sync=$SYNC santé=$HEALTH opération=$PHASE"
                    
                    if [ "$REV" = "$SHA" ] && [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ] && [ "$PHASE" = "Succeeded" ]; then
                        kubectl -n "$ENV_NAME" get pods,ingress
                        exit 0
                    fi
                    if [ "$OPREV" = "$SHA" ] && { [ "$PHASE" = "Failed" ] || [ "$PHASE" = "Error" ]; }; then
                        $A get application "$APP_NAME" -o jsonpath='{.status.operationState.message}'; echo
                        echo "Échec de la synchronisation ArgoCD pour $ENV_NAME." >&2
                        exit 1
                    fi
                    sleep 10
                done
                echo "Délai dépassé : $APP_NAME n'est pas Healthy après 20 minutes." >&2
                exit 1
            '''
        }
    }
}

// Delete ArgoCD Application, namespace and volume for the given environment. Data remains on the node disk (hostPath) : nothing is deleted in the filesystem.
def cleanEnv(String envName) {
    withEnv(["ENV_NAME=${envName}"]) {
        withCredentials([file(credentialsId: 'kubeconfig-cluster', variable: 'KUBECONFIG')]) {
            sh '''
                set -eu
                echo "Nettoyage de l'environnement $ENV_NAME"
                kubectl -n argocd delete application "fastapi-$ENV_NAME" --ignore-not-found --wait=true --timeout=5m
                kubectl delete namespace "$ENV_NAME" --ignore-not-found --wait=true --timeout=5m
                kubectl delete pv "db-pv-$ENV_NAME" --ignore-not-found
            '''
        }
    }
}

pipeline {
    agent any

    parameters {
        choice(name: 'ACTION', choices: ['pipeline', 'clean-only'],
               description: 'pipeline : CI + déploiement. clean-only : ne fait que supprimer les environnements choisis ci-dessous.')
        choice(name: 'CLEAN_ENVS', choices: ['none', 'dev', 'staging', 'qa', 'prod', 'dev+staging+qa', 'all'],
               description: 'Utilisé seulement avec ACTION = clean-only.')
    }

    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timeout(time: 2, unit: 'DAYS')
        disableConcurrentBuilds(abortPrevious: false)
    }

    environment {
        IMAGE_REPO         = 'apiforgesolutions/fastapi-traefik'   // Docker Hub repository (backend + frontend)
        DOCKER_USER        = 'apiforgesolutions'                   // Docker Hub account name
        MANIFESTS_REPO_URL = 'https://github.com/ApiForge-Solutions/manifests.git'
        MANIFESTS_BRANCH   = 'main'
        DOCKER_BUILDKIT    = '1'
    }

    stages {

        stage('Initialisation') {
            steps {
                script {
                    env.GIT_SHA      = sh(script: 'git rev-parse --short=8 HEAD', returnStdout: true).trim()
                    env.BACKEND_TAG  = "backend-${env.GIT_SHA}"
                    env.FRONTEND_TAG = "frontend-${env.GIT_SHA}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${params.ACTION} @${env.GIT_SHA}"
                }
            }
        }

        // #################### CLEANING ENVIRONMENTS #####################################################
        stage('Nettoyage des environnements') {
            when { expression { params.ACTION == 'clean-only' } }
            steps {
                script {
                    def targets = [
                        'none': [], 'dev': ['dev'], 'staging': ['staging'], 'qa': ['qa'], 'prod': ['prod'],
                        'dev+staging+qa': ['dev', 'staging', 'qa'], 'all': ['prod', 'qa', 'staging', 'dev']
                    ][params.CLEAN_ENVS]
                    if (targets.contains('prod')) {
                        timeout(time: 1, unit: 'HOURS') {
                            input(message: 'Supprimer l\'environnement de PRODUCTION (application, namespace, volume) ?',
                                  ok: 'Supprimer la production', submitter: 'admin')   // 
                        }
                    }
                    for (e in targets) {
                        lock('fastapi-environnements') { cleanEnv(e) }
                    }
                    echo targets ? "Nettoyé : ${targets.join(', ')}" : 'Rien à nettoyer (CLEAN_ENVS = none).'
                }
            }
        }

        // ------------------------------------------------------------------ CI
        stage('Test du code') {
            when { expression { params.ACTION == 'pipeline' } }
            steps {
                sh '''
                    set -eu
                    docker run --rm --label "ci-build=${BUILD_TAG}" \
                        -v "$WORKSPACE/backend/tests/unit:/unit:ro" python:3.12-slim \
                        sh -c "pip install -q --no-cache-dir pytest && pytest -q -p no:cacheprovider /unit"
                '''
            }
            post { always { script { ciClean() } } }
        }

        stage('Build des images') {
            when { expression { params.ACTION == 'pipeline' } }
            parallel {
                stage('Backend') {
                    steps { sh 'docker build -t "$IMAGE_REPO:$BACKEND_TAG" backend' }
                }
                stage('Frontend') {
                    steps {
                        sh 'docker build --build-arg VITE_API_URL= -t "$IMAGE_REPO:$FRONTEND_TAG" frontend'
                    }
                }
            }
        }

        stage('Test des images') {
            when { expression { params.ACTION == 'pipeline' } }
            stages {
                stage('Image backend (pytest + base de données)') {
                    steps {
                        script {
                            withEnv(["CI_NET=${ciNet('b')}"]) {
                                sh '''
                                    set -eu
                                    docker network create --label "ci-build=${BUILD_TAG}" "$CI_NET"
                                    docker run -d --name "${CI_NET}-db" --label "ci-build=${BUILD_TAG}" --network "$CI_NET" \
                                        -e POSTGRES_PASSWORD=ci-only -e POSTGRES_DB=app postgres:12

                                    # On teste l'image qui sera réellement déployée
                                    docker run --rm --label "ci-build=${BUILD_TAG}" --network "$CI_NET" \
                                        -e PROJECT_NAME=ci -e ENVIRONMENT=local \
                                        -e POSTGRES_SERVER="${CI_NET}-db" -e POSTGRES_PORT=5432 \
                                        -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=ci-only -e POSTGRES_DB=app \
                                        -e SECRET_KEY=ci-only-not-a-secret \
                                        -e FIRST_SUPERUSER=admin@example.com -e FIRST_SUPERUSER_PASSWORD=ci-only-password \
                                        -e EMAILS_FROM_EMAIL=info@example.com \
                                        "$IMAGE_REPO:$BACKEND_TAG" bash -c "bash scripts/prestart.sh && bash scripts/tests-start.sh"
                                '''
                            }
                        }
                    }
                    post { always { script { ciClean() } } }
                }
                stage('Image frontend (démarrage)') {
                    steps {
                        script {
                            withEnv(["CI_NET=${ciNet('f')}"]) {
                                sh '''
                                    set -eu
                                    docker network create --label "ci-build=${BUILD_TAG}" "$CI_NET"
                                    docker run -d --name "${CI_NET}-web" --label "ci-build=${BUILD_TAG}" --network "$CI_NET" \
                                        "$IMAGE_REPO:$FRONTEND_TAG"
                                    docker run --rm --label "ci-build=${BUILD_TAG}" --network "$CI_NET" curlimages/curl:8.10.1 \
                                        -fsS -o /dev/null --retry 10 --retry-delay 2 --retry-connrefused "http://${CI_NET}-web/"
                                '''
                            }
                        }
                    }
                    post { always { script { ciClean() } } }
                }
            }
        }

        stage('Push sur Docker Hub') {
            when { expression { params.ACTION == 'pipeline' } }
            environment { DOCKER_HUB_PASS = credentials('DOCKER_HUB_PASS') }
            steps {
                sh '''
                    set +x
                    echo "$DOCKER_HUB_PASS" | docker login -u "$DOCKER_USER" --password-stdin
                    docker push "$IMAGE_REPO:$BACKEND_TAG"
                    docker push "$IMAGE_REPO:$FRONTEND_TAG"
                '''
            }
            post { always { sh 'docker logout || true' } }
        }

        stage('Déploiement dev') {
            when { expression { params.ACTION == 'pipeline' } }
            steps { script { lock('fastapi-environnements') { promote('dev') } } }
        }

        stage('Déploiement staging') {
            when { expression { params.ACTION == 'pipeline' } }
            steps { script { lock('fastapi-environnements') { promote('staging') } } }
        }

        stage('Déploiement qa') {
            when { expression { params.ACTION == 'pipeline' } }
            steps { script { lock('fastapi-environnements') { promote('qa') } } }
        }

        stage('Validation production') {
            agent none
            when { expression { params.ACTION == 'pipeline' } }
            steps {
                script {
                    def decision = 'Ne pas déployer en production'
                    try {
                        timeout(time: 24, unit: 'HOURS') {
                            decision = input(
                                id: 'ValidationProduction',
                                message: "Déployer ${env.BACKEND_TAG} et ${env.FRONTEND_TAG} en PRODUCTION ?",
                                ok: 'Valider ma décision',
                                submitter: 'admin',      
                                parameters: [
                                    choice(name: 'DECISION',
                                           choices: ['Ne pas déployer en production', 'Déployer en production'],
                                           description: 'Commit ' + env.GIT_SHA + '. dev, staging et qa sont verts.')
                                ]
                            )
                        }
                    } catch (err) {
                        echo 'Aucune décision prise (abandon ou délai de 24 h) : la production n\'est pas déployée.'
                    }
                    env.DEPLOY_PROD = (decision == 'Déployer en production') ? 'true' : 'false'
                    currentBuild.description = (env.DEPLOY_PROD == 'true') ? 'Production : validée' : 'Production : non déployée'
                }
            }
        }

        stage('Déploiement prod') {
            when { environment name: 'DEPLOY_PROD', value: 'true' }
            steps { script { lock('fastapi-environnements') { promote('prod') } } }
        }
    }

    post {
        always {
            script {
                ciClean()
                sh '''
                    [ -n "${BACKEND_TAG:-}" ] && docker rmi -f "$IMAGE_REPO:$BACKEND_TAG" "$IMAGE_REPO:$FRONTEND_TAG" > /dev/null 2>&1 || true
                    rm -rf manifests-dev manifests-staging manifests-qa manifests-prod .manifests-sha-* || true
                '''
            }
        }
        failure {
            echo 'Échec. Un déploiement raté reste visible dans ArgoCD (Application fastapi-<env>) ; l\'état précédent est conservé tant que la synchronisation n\'a pas réussi.'
        }
    }
}
